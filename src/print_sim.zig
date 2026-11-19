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
//!   the reach of the round strand that leaves the nozzle) is solid at
//!   once at its place. So is a mass beside a bead of the same layer at its height, up to
//!   `side_reach` beads out from plastic that an earlier layer holds: the
//!   end of a bridge line welds to the wall, and an overhang wall leans on
//!   the wall inside it. A bead that hung does not hold the mass beside it,
//!   so a skin over air does not grow from line to line. Else the mass is
//!   soft.
//! - **Heat.** A soft mass cools toward the room by Newton's law: dT/dt =
//!   -(T - T_room) / tau, with tau = rho c (A / P) / h for a bead of area A
//!   and perimeter P (lumped heat). The heat transfer h is the still air
//!   value plus the forced value of the fan, from the Hilpert correlation
//!   for a cylinder in cross flow (diameter 4 A / P).
//! - **Viscosity.** Hot plastic flows. Its viscosity grows as it cools:
//!   the law of the melt of the material (`Material`: for PLA an
//!   Arrhenius law, 3546 Pa s at 200 °C and 80.6 kJ/mol, from the
//!   measurements of Colón Quintana 2021), and the WLF law near the glass
//!   point (Williams, Landel, and Ferry 1955), whichever is larger. A soft
//!   mass sets (it is solid where it is) when its viscosity passes
//!   `set_visc`.
//! - **Contact.** A soft mass that comes down onto the bed or solid plastic
//!   sets there. It rests on the highest plastic under its bead, so it
//!   does not fall through a gap narrower than itself.
//! - **Failure.** A mass that sets more than `fail_drop` under its place
//!   failed. The next layers have no plastic under them there, so they
//!   fall onto it and fail too, until a layer can bridge to solid plastic.
//! - **Runs.** The soft masses of a chain make runs between masses that
//!   something holds: a solid mass, or the newest mass, which the nozzle
//!   holds while the path prints.
//!   - A run held at both ends (a bridge, or a strand from an edge to the
//!     nozzle) hangs in its exact static shape: a catenary of the arc
//!     length of the run between its two ends. The catenary is in the
//!     vertical surface over the route where the nozzle laid the run. The
//!     route must be about straight: nothing holds a turn, so the tension
//!     pulls a run with a turn (a slab edge over air, a zigzag) off its
//!     plan, and the run swings and falls (below).
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
    /// The path goes on from the end of the path before it with no break
    /// of the strand (no travel): one strand of plastic. A wall that the
    /// slicer splits into pieces over air and on plastic is one strand.
    joined: bool = false,
};

/// The bead of a path: half its height, its width, rho c A / P in SI
/// units (the cooling time is heat / h), and the hydraulic diameter 4 A /
/// P (mm).
const Bead = struct {
    half_h: f32,
    width: f32,
    heat: f32,
    diam: f32,
    /// The gap under the bead that the plastic fills with no fall (mm).
    /// Out of the nozzle, the plastic is a round strand of the bead area
    /// (its diameter is sqrt(4 A / pi)). The nozzle presses it flat to the
    /// bead height on what is under it. So the strand reaches down past
    /// the bottom of the bead by the diameter less the bead height.
    reach: f32,

    fn of(path: Path, p: Params) Bead {
        const area = if (path.area > 0) path.area else beadArea(path.width, path.height);
        // The bead perimeter: a stadium of the bead width and height.
        const perim = if (path.width > path.height) 2 * (path.width - path.height) + std.math.pi * path.height else std.math.pi * path.width;
        return .{
            .half_h = 0.5 * path.height,
            .width = path.width,
            .heat = p.material.density * 1e6 * p.material.heat_capacity * (area / perim) * 1e-3,
            .diam = 4 * area / perim,
            .reach = @max(@sqrt(4 * area / std.math.pi) - path.height, 0),
        };
    }
};

/// A plastic: the viscosity of its melt and its law of temperature, its
/// glass point, and its heat. The sources are in REFERENCES.md.
pub const Material = struct {
    name: []const u8,
    /// The zero-shear viscosity of the melt (Pa s) at `visc_ref_t` (°C).
    visc_ref: f32,
    visc_ref_t: f32,
    /// The law of temperature of the melt: the Arrhenius law with this
    /// activation energy (J/mol), or with 0 the WLF law with the
    /// constants `visc_wlf` (C1, and C2 in K): log10 a = -C1 (T - Tref) /
    /// (C2 + T - Tref).
    visc_ea: f32 = 0,
    visc_wlf: [2]f32 = .{ 0, 0 },
    /// The glass point (°C).
    glass_t: f32,
    /// The density (g/mm³), the heat capacity (J/(kg K)), and the heat
    /// conductivity (W/(m K)) of the solid.
    density: f32,
    heat_capacity: f32,
    conductivity: f32,
    /// The values that come from no measurement of this plastic, in words.
    estimates: []const u8 = "",
};

/// PLA (MatterHackers PLA), as Colón Quintana (2021) measured it: 3546 Pa
/// s at 200 °C, Arrhenius with 80.6 kJ/mol, the glass point at 58.9 °C,
/// and the density, heat capacity, and conductivity of the sources of
/// that work.
pub const pla: Material = .{
    .name = "PLA",
    .visc_ref = 3546,
    .visc_ref_t = 200,
    .visc_ea = 80574.4,
    .glass_t = 58.9,
    .density = 1.25e-3,
    .heat_capacity = 1800,
    .conductivity = 0.163,
};

/// ABS (MG94), as Colón Quintana (2021) measured it: 13 250 Pa s at 200
/// °C, the WLF law with C1 = 3.938 and C2 = 128.6 K, the glass point at
/// 104.5 °C.
pub const abs: Material = .{
    .name = "ABS",
    .visc_ref = 13250,
    .visc_ref_t = 200,
    .visc_wlf = .{ 3.93791, 128.563 },
    .glass_t = 104.5,
    .density = 1.06e-3,
    .heat_capacity = 1381,
    .conductivity = 0.17,
};

/// PETG: a melt viscosity of 2880 to 4810 Pa s at 1 rad/s and 220 °C (US
/// patent 9,962,913; the middle is 3844 Pa s), the glass point at 80 °C
/// and the density of a filament data sheet (3D Universe). No open
/// measurement gives its law of temperature, its heat capacity, or its
/// conductivity: these are the values of PLA.
pub const petg: Material = .{
    .name = "PETG",
    .visc_ref = 3844,
    .visc_ref_t = 220,
    .visc_ea = 80574.4,
    .glass_t = 80,
    .density = 1.29e-3,
    .heat_capacity = 1800,
    .conductivity = 0.163,
    .estimates = "the law of temperature, the heat capacity, and the conductivity are those of PLA",
};

pub const materials = [_]Material{ pla, abs, petg };

/// The material of the simulation for a filament type ("PLA", "ABS",
/// "PETG"), and if it is the same plastic. A type with no data of its own
/// gets the nearest plastic: ASA and HIPS (styrene plastics) get ABS, PET
/// and PCTG (polyesters) get PETG, and any other type gets PLA.
pub fn materialFor(kind: []const u8) struct { material: Material, exact: bool } {
    for (materials) |m| if (std.ascii.eqlIgnoreCase(kind, m.name)) return .{ .material = m, .exact = true };
    const near = [_]struct { []const u8, Material }{
        .{ "ASA", abs }, .{ "HIPS", abs }, .{ "PET", petg }, .{ "PCTG", petg },
    };
    for (near) |n| if (std.ascii.startsWithIgnoreCase(kind, n[0])) return .{ .material = n[1], .exact = false };
    return .{ .material = pla, .exact = false };
}

pub const Params = struct {
    nozzle_t: f32 = 210,
    /// The air around the print (°C): the room, or a heated chamber.
    room_t: f32 = 25,
    /// The bed (°C), and the thickness of the warm air over it (mm). Over a
    /// hot plate the air is warm in a layer of about L Ra^(-1/4) (laminar
    /// natural convection): about 3 mm over 100 mm of a bed at 60 °C. The
    /// air at the height z over the bed is room_t + (bed_t - room_t)
    /// exp(-z / bed_layer).
    bed_t: f32 = 25,
    bed_layer: f32 = 3,
    /// The plastic: its flow, its glass point, and its heat.
    material: Material = pla,
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
    /// The step (s) while no soft mass swings or falls: the runs only hang
    /// in their closed form, which is stable at any step.
    dt_hang: f32 = 0.002,
    /// The Gauss-Seidel passes of a run that fell.
    iterations: u32 = 8,
    /// The share of the follow-the-leader correction that goes back into
    /// the speed of the mass before (Müller et al. 2012 call it s_damping).
    ftl_damp: f32 = 0.9,
    /// The mass spacing (mm), or 0 for half the bead width.
    spacing: f32 = 0,
    /// The cell of the height field (mm).
    cell: f32 = 0.1,
    /// A new mass welds to a bead of its layer beside it, if that bead is
    /// fewer than this many beads from plastic that an earlier layer
    /// holds. A bead over air then holds the next, up to this count.
    side_reach: u8 = 2,
    /// A path whose masses all set within this distance (mm) of their
    /// place did not move.
    move_eps: f32 = 0.01,
    /// A mass that sets more than this (mm) under its place failed: the
    /// next layers print on air there. Yang et al. (2021) measured about
    /// 1 to 1.5 mm of sag in the deck of a 35 mm PLA bridge at the limit
    /// of a good print; longer bridges hung in loose strands.
    fail_drop: f32 = 1.5,
    /// Keep the masses of all paths in the result, also of the paths that
    /// did not move (for tests).
    keep_all: bool = false,
};

/// The viscosity of PLA at t °C (Pa s): Arrhenius in the melt, WLF near
/// the glass point, whichever is larger. Infinite at the glass point.
pub fn viscosity(p: Params, t: f32) f32 {
    const m = p.material;
    if (t <= m.glass_t) return std.math.inf(f32);
    // The law of the melt: Arrhenius, or WLF with the constants of the
    // material (below the pole of the law, it does not hold).
    const melt = if (m.visc_ea > 0)
        m.visc_ref * @exp(m.visc_ea / 8.314 * (1 / (t + 273.15) - 1 / (m.visc_ref_t + 273.15)))
    else blk: {
        const x = t - m.visc_ref_t;
        if (m.visc_wlf[1] + x <= 1) break :blk std.math.inf(f32);
        break :blk m.visc_ref * @exp(-m.visc_wlf[0] * x / (m.visc_wlf[1] + x) * std.math.ln10);
    };
    // WLF with the universal constants C1 = 17.44, C2 = 51.6 K near the
    // glass point.
    const d = t - m.glass_t;
    const wlf = p.visc_glass * @exp(-17.44 * d / (51.6 + d) * std.math.ln10);
    return @max(melt, wlf);
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
    var lo = p.material.glass_t;
    var hi = @max(p.nozzle_t, p.material.glass_t + 1);
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
    /// The masses that failed (see `Params.fail_drop`), and the first
    /// layer with a failed mass (`none` if no mass failed).
    failed: usize = 0,
    first_failed_layer: u32 = none,
    /// The largest drop of a mass under its place (mm).
    max_drop: f32 = 0,
};

pub const Result = struct {
    /// For each path: the first entry in `pos` and the count. The count is
    /// 0 for a path whose masses all set where it printed (unless
    /// `keep_all`).
    ranges: [][2]u32,
    /// The places where the masses set: the centers of their beads.
    pos: []V,
    /// The places where the slicer meant each entry of `pos` to be.
    want: []V,
    /// The print time (s) when each entry of `pos` set: when it came out
    /// of the nozzle, for a mass that was solid at once.
    set_time: []f32,
    /// The mass of each entry of `pos` (g), with `keep_all` only.
    mass: []f32,
    /// For each path: the largest drop of a mass under its place (mm),
    /// and its failed masses.
    drop: []f32,
    failed: []u32,
    stats: Stats,

    pub fn nodes(r: *const Result, path: usize) []const V {
        const g = r.ranges[path];
        return r.pos[g[0]..][0..g[1]];
    }

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.ranges);
        gpa.free(r.pos);
        gpa.free(r.want);
        gpa.free(r.set_time);
        gpa.free(r.mass);
        gpa.free(r.drop);
        gpa.free(r.failed);
    }
};

pub const none = std.math.maxInt(u32);

/// The height field of the solid plastic: the top z of each cell, the
/// layer that put it there, the top of the layers before that layer, and
/// the reach of the plastic of the cell: 0 if an earlier layer (or the
/// bed) holds it, k if it is k beads beside such plastic in its layer,
/// and `hung` if it hung or fell before it set. A cell with no plastic is
/// the bed (top 0).
const Field = struct {
    const n = 32;
    const hung = std.math.maxInt(u8);
    const Tile = struct { top: [n * n]f32, under: [n * n]f32, layer: [n * n]u32, reach: [n * n]u8 };
    const Cell = struct { top: f32, under: f32, layer: u32, reach: u8 };

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
        const bed: Cell = .{ .top = 0, .under = 0, .layer = none, .reach = 0 };
        const l = f.locate(x, y) orelse return bed;
        const t = f.tiles[l[0]] orelse return bed;
        const i = l[1];
        return .{ .top = t.top[i], .under = t.under[i], .layer = t.layer[i], .reach = t.reach[i] };
    }

    fn raise(f: *Field, x: f32, y: f32, top: f32, layer: u32, reach: u8) Allocator.Error!void {
        const l = f.locate(x, y) orelse return;
        const t = f.tiles[l[0]] orelse blk: {
            const t = try f.arena.allocator().create(Tile);
            @memset(&t.top, 0);
            @memset(&t.under, 0);
            @memset(&t.layer, none);
            @memset(&t.reach, 0);
            f.tiles[l[0]] = t;
            break :blk t;
        };
        const i = l[1];
        if (top < t.top[i]) return;
        // A new layer: the top so far is the top of the layers before it.
        const same = t.layer[i] == layer;
        if (!same) t.under[i] = t.top[i];
        t.reach[i] = if (same) @min(reach, t.reach[i]) else reach;
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
    /// Its path.
    path: u32,
    /// The print time when it set, or came out of the nozzle.
    set_at: f32,
    soft: bool,
    /// It swung or fell: a run with such a mass does not hang as a
    /// catenary.
    fell: bool = false,
};

/// The masses of one strand (a path, or paths joined with no break),
/// while it prints or has soft masses.
const Chain = struct {
    layer: u32,
    nodes: std.ArrayList(Node),
    /// The soft masses are in [lo, hi).
    lo: usize = 0,
    hi: usize = 0,
    soft: usize = 0,
    /// The nozzle holds the newest mass.
    head: bool = true,

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

/// A point of the plan route of a hanging run, and its distance along the
/// route.
const RoutePoint = struct { xy: [2]f32, d: f64 };

/// If no point of the route is farther than `tol` (mm) from the straight
/// line between its two ends, in plan.
fn straightRoute(route: []const RoutePoint, tol: f32) bool {
    const a = route[0].xy;
    const b = route[route.len - 1].xy;
    const ux = b[0] - a[0];
    const uy = b[1] - a[1];
    const l = std.math.hypot(ux, uy);
    if (!(l > 1e-6)) return false;
    for (route[1 .. route.len - 1]) |r| {
        const off = @abs((r.xy[0] - a[0]) * uy - (r.xy[1] - a[1]) * ux) / l;
        if (off > tol) return false;
    }
    return true;
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
    route: std.ArrayList(RoutePoint) = .empty,
    /// The cached disks of `disk`.
    disks: [2]struct { r: f32 = -1, offsets: std.ArrayList([2]f32) = .empty } = .{ .{}, .{} },
    time: f64 = 0,
    fan: f32 = 0,
    /// The soft masses, and if the newest one is soft (the nozzle holds it).
    soft: usize = 0,
    head_soft: bool = false,
    /// The soft masses that swung or fell.
    fell_soft: usize = 0,
    set_t: f32,
    rho_g: f32,
    ranges: [][2]u32,
    drop: []f32,
    failed: []u32,
    pos: std.ArrayList(V) = .empty,
    want: std.ArrayList(V) = .empty,
    set_time: std.ArrayList(f32) = .empty,
    mass: std.ArrayList(f32) = .empty,
    stats: Stats = .{},

    fn deinit(s: *Sim) void {
        for (s.chains.items) |*c| c.nodes.deinit(s.gpa);
        s.chains.deinit(s.gpa);
        for (s.spare.items) |*l| l.deinit(s.gpa);
        s.spare.deinit(s.gpa);
        s.scratch.deinit(s.gpa);
        s.weights.deinit(s.gpa);
        s.route.deinit(s.gpa);
        for (&s.disks) |*d| d.offsets.deinit(s.gpa);
        s.field.deinit(s.gpa);
        s.pos.deinit(s.gpa);
        s.want.deinit(s.gpa);
        s.set_time.deinit(s.gpa);
        s.mass.deinit(s.gpa);
        s.gpa.free(s.ranges);
        s.gpa.free(s.drop);
        s.gpa.free(s.failed);
    }

    /// The top of the plastic under a bead of width `w` at (x, y) that a
    /// mass with its center at `zc` can rest on: the highest top under the
    /// bead, at its center and at four points around it. A top above the
    /// center is beside it or above it. So a bead does not fall through a
    /// gap between two beads under it that is narrower than itself.
    fn floorAt(s: *const Sim, x: f32, y: f32, zc: f32, w: f32) f32 {
        const r = 0.35 * w;
        var floor: f32 = 0;
        for ([_][2]f32{ .{ 0, 0 }, .{ r, 0 }, .{ -r, 0 }, .{ 0, r }, .{ 0, -r } }) |o| {
            const top = s.field.at(x + o[0], y + o[1]).top;
            if (top <= zc) floor = @max(floor, top);
        }
        return floor;
    }

    /// What holds a new mass at p: the reach of its plastic (see Field),
    /// or `Field.hung` if it is soft. The bed or an earlier layer under its
    /// bead gives 0. A bead of the same layer beside it at its height, of
    /// reach k, gives k + 1 up to `side_reach` (the end of a bridge line
    /// welds to the wall). So a skin over air grows only a few lines from
    /// the plastic that an earlier layer holds.
    fn supported(s: *Sim, layer: u32, b: Bead, p: V, dir: [2]f32) Allocator.Error!u8 {
        const bottom = p[2] - b.half_h;
        const tol = b.reach;
        if (bottom <= tol) return 0;
        const top = p[2] + b.half_h;
        // The cells under the bead, the nearest first: most beads have
        // plastic under their middle, and the first such cell ends the
        // search.
        for (try s.disk(0, 0.5 * b.width)) |o| {
            const q = s.field.at(p[0] + o[0], p[1] + o[1]);
            if (q.layer == none) continue;
            // Plastic of an earlier layer under the bead, or a heap
            // above the nozzle that the nozzle plows into.
            const base = if (q.layer == layer) q.under else q.top;
            if (base >= bottom - tol or q.top > top + tol) return 0;
        }
        // A bead beside it: on each side, across the path. The strand
        // before it in the path is behind it, and holds it only by its
        // links.
        var side: u8 = Field.hung;
        for ([_]f32{ -1, 1 }) |sign| for ([_]f32{ 0.35, 0.5, 0.65 }) |f| {
            const o = sign * f * b.width;
            const q = s.field.at(p[0] - dir[1] * o, p[1] + dir[0] * o);
            if (q.layer == layer and q.reach < s.p.side_reach and @abs(q.top - top) <= tol) side = @min(side, q.reach + 1);
        };
        return side;
    }

    /// Writes the bead of a solid mass into the height field, with its
    /// reach (see Field).
    fn deposit(s: *Sim, layer: u32, b: Bead, p: V, reach: u8) Allocator.Error!void {
        const top = p[2] + b.half_h;
        for (try s.disk(1, 0.45 * b.width)) |o| try s.field.raise(p[0] + o[0], p[1] + o[1], top, layer, reach);
    }

    /// The offsets (mm) of the cells of the height field in a disk of
    /// radius r, the nearest first. Two disks stay in a cache (`slot`): the
    /// support test and the deposit of a bead.
    fn disk(s: *Sim, slot: usize, r: f32) Allocator.Error![]const [2]f32 {
        const d = &s.disks[slot];
        if (d.r == r) return d.offsets.items;
        d.r = r;
        d.offsets.clearRetainingCapacity();
        const cell = s.field.cell;
        const k: i32 = @intFromFloat(@ceil(r / cell));
        var dy = -k;
        while (dy <= k) : (dy += 1) {
            var dx = -k;
            while (dx <= k) : (dx += 1) {
                const ox = @as(f32, @floatFromInt(dx)) * cell;
                const oy = @as(f32, @floatFromInt(dy)) * cell;
                if (ox * ox + oy * oy > r * r) continue;
                d.offsets.append(s.gpa, .{ ox, oy }) catch |e| {
                    d.r = -1;
                    return e;
                };
            }
        }
        std.mem.sort([2]f32, d.offsets.items, {}, struct {
            fn lt(_: void, a: [2]f32, b: [2]f32) bool {
                return a[0] * a[0] + a[1] * a[1] < b[0] * b[0] + b[1] * b[1];
            }
        }.lt);
        return d.offsets.items;
    }

    fn setSolid(s: *Sim, c: *Chain, k: usize) Allocator.Error!void {
        const n = &c.nodes.items[k];
        n.soft = false;
        n.prev = n.pos;
        n.set_at = @floatCast(s.time);
        if (n.fell) s.fell_soft -= 1;
        c.soft -= 1;
        s.soft -= 1;
        try s.deposit(c.layer, s.bead(n.path), n.pos, Field.hung);
    }

    /// The temperature of the air at the height z (°C): the room, and
    /// warmer near a hot bed. Never at the set point: plastic that cannot
    /// set is out of the model.
    fn airAt(s: *const Sim, z: f32) f32 {
        const p = s.p;
        const air = p.room_t + (p.bed_t - p.room_t) * @exp(-@max(z, 0) / p.bed_layer);
        return @min(air, s.set_t - 10);
    }

    fn current(s: *Sim) *Chain {
        return &s.chains.items[s.chains.items.len - 1];
    }

    fn bead(s: *const Sim, path: u32) Bead {
        return Bead.of(s.paths[path], s.p);
    }

    /// Emits the next mass of path `pi` (the current strand) at p.
    fn emit(s: *Sim, pi: u32, b: Bead, p: V, dir: [2]f32, rest: f32, mass_per_mm: f32) Allocator.Error!void {
        const c = s.current();
        const k = c.nodes.items.len;
        // The newest mass before this one is no longer at the nozzle.
        if (k > 0) {
            c.nodes.items[k - 1].mass += 0.5 * rest * mass_per_mm;
            s.head_soft = false;
        }
        try c.nodes.append(s.gpa, .{ .pos = p, .prev = p, .want = p, .temp = s.p.nozzle_t, .rest = rest, .mass = 0.5 * rest * mass_per_mm, .path = pi, .set_at = @floatCast(s.time), .soft = true });
        const reach = try s.supported(c.layer, b, p, dir);
        if (reach != Field.hung) {
            c.nodes.items[k].soft = false;
            try s.deposit(c.layer, b, p, reach);
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
            const step_dt = if (s.fell_soft > 0) s.p.dt else s.p.dt_hang;
            const dt: f32 = @floatCast(@min(@as(f64, step_dt), t - s.time));
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

    /// Writes the masses of each path of a strand to the result.
    fn finish(s: *Sim, c: *const Chain) Allocator.Error!void {
        const all = c.nodes.items;
        s.stats.masses += all.len;
        var a: usize = 0;
        while (a < all.len) {
            var b = a + 1;
            while (b < all.len and all[b].path == all[a].path) b += 1;
            const nodes = all[a..b];
            const half_h = 0.5 * s.paths[nodes[0].path].height;
            var moved = false;
            const pi = nodes[0].path;
            for (nodes) |n| {
                const d = len3(sub(n.pos, n.want));
                s.stats.max_move = @max(s.stats.max_move, d);
                if (d > half_h) s.stats.moved += 1;
                if (d > s.p.move_eps) moved = true;
                s.stats.mass += n.mass;
                const drop = n.want[2] - n.pos[2];
                s.drop[pi] = @max(s.drop[pi], drop);
                if (drop > s.p.fail_drop) {
                    s.failed[pi] += 1;
                    s.stats.failed += 1;
                    s.stats.first_failed_layer = @min(s.stats.first_failed_layer, s.paths[pi].layer);
                }
            }
            s.stats.max_drop = @max(s.stats.max_drop, s.drop[pi]);
            if (moved) s.stats.moved_paths += 1;
            if (moved or s.p.keep_all) {
                s.ranges[nodes[0].path] = .{ @intCast(s.pos.items.len), @intCast(nodes.len) };
                for (nodes) |n| {
                    try s.pos.append(s.gpa, n.pos);
                    try s.want.append(s.gpa, n.want);
                    try s.set_time.append(s.gpa, n.set_at);
                    if (s.p.keep_all) try s.mass.append(s.gpa, n.mass);
                }
            }
            a = b;
        }
    }

    fn stepChain(s: *Sim, c: *Chain, dt: f32) Allocator.Error!void {
        const p = s.p;
        const nodes = c.nodes.items;
        // The cooling of each path of the strand.
        var decay_path: u32 = none;
        var decay: f32 = 1;
        for (c.lo..c.hi) |k| if (!c.pinned(k)) {
            if (nodes[k].path != decay_path) {
                decay_path = nodes[k].path;
                const b = s.bead(decay_path);
                decay = @exp(-dt * heatTransfer(p, s.fan, b.diam) / b.heat);
            }
            const air = s.airAt(nodes[k].pos[2]);
            nodes[k].temp = air + (nodes[k].temp - air) * decay;
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
            const half_h = 0.5 * s.paths[n.path].height;
            const top = s.floorAt(n.pos[0], n.pos[1], @max(n.pos[2], n.prev[2]), s.paths[n.path].width);
            if (n.pos[2] - half_h <= top + 1e-3) {
                n.pos[2] = @max(n.pos[2], top + half_h);
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
        // The route in plan: from the held end, along the places where the
        // nozzle laid the masses, to the other held end. The strand hangs
        // along it, so a run with a turn (a zigzag of infill) keeps its
        // plan.
        try s.route.resize(s.gpa, j + 3 - k);
        const route = s.route.items;
        route[0] = .{ .xy = .{ a[0], a[1] }, .d = 0 };
        for (k..j + 2) |m| {
            const q = if (m == j + 1) b else nodes[m].want;
            const prev = route[m - k].xy;
            route[m + 1 - k] = .{ .xy = .{ q[0], q[1] }, .d = route[m - k].d + std.math.hypot(@as(f64, q[0] - prev[0]), @as(f64, q[1] - prev[1])) };
        }
        const dz: f64 = b[2] - a[2];
        const dh = route[route.len - 1].d;
        if (dh < 0.05 * arc or arc * arc <= dz * dz + 1e-12) return false;
        // Nothing holds a turn of the route: the tension pulls the strand
        // to the straight line between its ends, and gravity pulls it
        // down. A run whose route leaves that line by more than half a
        // bead swings and falls.
        if (!straightRoute(route, 0.5 * s.bead(nodes[k].path).width)) return false;
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
        const r = lp / dh;
        const taut = r - 1 < 1e-9;
        const u = if (taut) 0 else catenaryU(r);
        const ca = if (taut) 0 else dh / (2 * u);
        const q = if (taut) 0 else u - atanh(dz / arc);
        const sq = sinh(q);
        var along: f64 = 0;
        var seg: usize = 0;
        for (k..j + 1) |m| {
            along += nodes[m].rest;
            // The place along the route (x), and the height (z).
            var x: f64 = undefined;
            var z: f64 = undefined;
            if (taut) {
                x = dh * along / arc;
                z = dz * along / arc;
            } else {
                const xi = asinh(along / ca - sq);
                x = ca * (xi + q);
                z = 2 * ca * sinh((xi + q) / 2) * sinh((xi - q) / 2);
            }
            while (seg + 2 < route.len and route[seg + 1].d < x) seg += 1;
            const r0 = route[seg];
            const r1 = route[seg + 1];
            const f = if (r1.d > r0.d) std.math.clamp((x - r0.d) / (r1.d - r0.d), 0, 1) else 0;
            nodes[m].prev = nodes[m].pos;
            nodes[m].pos = .{
                @floatCast(r0.xy[0] + (r1.xy[0] - r0.xy[0]) * f),
                @floatCast(r0.xy[1] + (r1.xy[1] - r0.xy[1]) * f),
                @floatCast(a[2] + z),
            };
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
                const half_h = 0.5 * s.paths[n.path].height;
                const top = s.floorAt(n.pos[0], n.pos[1], @max(n.pos[2], n.prev[2]), s.paths[n.path].width);
                if (n.pos[2] - half_h < top) n.pos[2] = top + half_h;
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
        for (nodes[k .. j + 1]) |*n| if (!n.fell) {
            n.fell = true;
            s.fell_soft += 1;
        };
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
        const mass_per_mm = s.p.material.density * area;
        const bead_of = Bead.of(path, s.p);
        // A joined path goes on with the strand before it, if the nozzle
        // still holds it. Its first point is the end of that strand.
        const cont = path.joined and s.chains.items.len > 0 and s.current().head and s.current().layer == path.layer;
        if (cont) {
            s.current().head = true;
        } else {
            s.endStrand();
            const nodes = if (s.spare.pop()) |l| l else std.ArrayList(Node).empty;
            try s.chains.append(s.gpa, .{ .layer = path.layer, .nodes = nodes });
        }
        var last_want: V = undefined;
        if (cont) last_want = s.current().nodes.items[s.current().nodes.items.len - 1].want;
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
            if (cont and i == 0) continue;
            const rest = if (i == 0) 0 else if (cont and i == 1) len3(sub(p, last_want)) else step_len;
            try s.runTo(t);
            const sl = @max(seg_len, 1e-9);
            try s.emit(pi, bead_of, p, .{ (b[0] - a[0]) / sl, (b[1] - a[1]) / sl }, rest, mass_per_mm);
        }
    }

    /// The nozzle leaves the strand that prints: its end hangs free.
    fn endStrand(s: *Sim) void {
        if (s.chains.items.len == 0) return;
        s.current().head = false;
        s.head_soft = false;
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
    const drop = gpa.alloc(f32, paths.len) catch |e| {
        gpa.free(ranges);
        return e;
    };
    @memset(drop, 0);
    const failed = gpa.alloc(u32, paths.len) catch |e| {
        gpa.free(ranges);
        gpa.free(drop);
        return e;
    };
    @memset(failed, 0);
    var s: Sim = .{
        .gpa = gpa,
        .p = params,
        .paths = paths,
        .field = undefined,
        .set_t = setTemperature(params),
        .rho_g = params.material.density * params.gravity,
        .ranges = ranges,
        .drop = drop,
        .failed = failed,
    };
    s.field = Field.init(gpa, .{ lo[0] - margin, lo[1] - margin }, .{ hi[0] + margin, hi[1] + margin }, params.cell) catch |e| {
        gpa.free(ranges);
        gpa.free(drop);
        gpa.free(failed);
        return e;
    };
    defer s.deinit();
    for (paths, 0..) |path, pi| try s.print(@intCast(pi), path);
    s.endStrand();
    // The last soft masses set: they cool below the set point in seconds.
    try s.runTo(s.time + 3600);
    for (s.chains.items) |*c| c.head = false;
    try s.finishChains();
    const pos = try s.pos.toOwnedSlice(gpa);
    errdefer gpa.free(pos);
    const want = try s.want.toOwnedSlice(gpa);
    errdefer gpa.free(want);
    const set_time = try s.set_time.toOwnedSlice(gpa);
    errdefer gpa.free(set_time);
    const mass = try s.mass.toOwnedSlice(gpa);
    const out_ranges = s.ranges;
    s.ranges = &.{};
    const out_drop = s.drop;
    s.drop = &.{};
    const out_failed = s.failed;
    s.failed = &.{};
    return .{ .ranges = out_ranges, .pos = pos, .want = want, .set_time = set_time, .mass = mass, .drop = out_drop, .failed = out_failed, .stats = s.stats };
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
    room_t: f32 = 25,
    fan_air: f32 = 6,
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
    var r = try run(gpa, paths[0..n], .{ .nozzle_t = b.nozzle_t, .room_t = b.room_t, .fan_air = b.fan_air, .keep_all = true });
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

test "print sim: a warm chamber or a weak fan makes a bridge sag more" {
    const gpa = testing.allocator;
    const base = try bridgeSag(gpa, .{});
    try testing.expect(try bridgeSag(gpa, .{ .room_t = 60 }) > base);
    try testing.expect(try bridgeSag(gpa, .{ .fan_air = 2 }) > base);
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

/// Two posts with a gap of 2 mm, 10 layers high, then a wall over them
/// in three pieces, as a slicer splits a wall over air: the middle piece
/// is all over air.
fn splitWall(gpa: Allocator, joined: bool) !f32 {
    var pts: [23][2][2]f32 = undefined;
    var paths: [23]Path = undefined;
    var n: usize = 0;
    for (0..10) |k| {
        const z = 0.2 * @as(f32, @floatFromInt(k + 1));
        const t = 4 * @as(f32, @floatFromInt(k));
        paths[n] = line(.{ 0, 0 }, .{ 3, 0 }, z, @intCast(k), t, 40, 1, &pts[n]);
        n += 1;
        paths[n] = line(.{ 5, 0 }, .{ 8, 0 }, z, @intCast(k), t + 1, 40, 1, &pts[n]);
        n += 1;
    }
    const xs = [_]f32{ 0, 3.6, 4.4, 8 };
    var t: f32 = 41;
    for (0..3) |i| {
        paths[n] = line(.{ xs[i], 0 }, .{ xs[i + 1], 0 }, 2.2, 10, t, 30, 1, &pts[n]);
        paths[n].joined = joined and i > 0;
        t = paths[n].t1;
        n += 1;
    }
    var r = try run(gpa, paths[0..n], .{ .keep_all = true });
    defer r.deinit(gpa);
    var low: f32 = 100;
    for (r.nodes(n - 2)) |q| low = @min(low, q[2]);
    return low;
}

test "print sim: the pieces of one strand hold each other" {
    const gpa = testing.allocator;
    // One strand: the middle piece is a short bridge.
    try testing.expect(try splitWall(gpa, true) > 2.1 - 0.2);
    // Separate strands: the middle piece has no hold, and falls.
    try testing.expect(try splitWall(gpa, false) < 0.5);
}

/// A post of 4 x 4 mm, 10 layers high, then 6 layers of a slab of 20 x 4
/// mm on it: a loop, and skin lines along x. 8 mm of each end of the slab
/// is over air. Returns the result, the plastic (g), and the first and
/// the end path of the slab.
fn shelf(gpa: Allocator, params: Params) !struct { Result, f64, usize, usize } {
    const post_layers = 10;
    const slab_layers = 6;
    const lines = 8;
    const count = post_layers + slab_layers * (1 + lines);
    var pts: [count][6][2]f32 = undefined;
    var paths: [count]Path = undefined;
    var t: f32 = 0;
    var volume: f64 = 0;
    var n: usize = 0;
    for (0..post_layers + slab_layers) |k| {
        const z = 0.2 * @as(f32, @floatFromInt(k + 1));
        const hx: f32 = if (k < post_layers) 2 else 10;
        // A loop that starts and ends at the middle of an edge over the
        // post.
        pts[n] = .{ .{ 0, -2 }, .{ hx, -2 }, .{ hx, 2 }, .{ -hx, 2 }, .{ -hx, -2 }, .{ 0, -2 } };
        var shape: []const [2]f32 = &pts[n];
        for (0..(if (k < post_layers) 1 else 1 + lines)) |i| {
            if (i > 0) {
                // The skin lines, each a path of its own, back and forth.
                const y = -1.55 + 0.45 * @as(f32, @floatFromInt(i - 1));
                const x: f32 = if (i % 2 == 0) -9.6 else 9.6;
                pts[n][0] = .{ -x, y };
                pts[n][1] = .{ x, y };
                shape = pts[n][0..2];
            }
            var l: f32 = 0;
            for (shape[1..], shape[0 .. shape.len - 1]) |b, a| l += std.math.hypot(b[0] - a[0], b[1] - a[1]);
            paths[n] = .{ .xy = shape, .z = z, .height = 0.2, .width = 0.45, .t0 = t, .t1 = t + l / 30, .fan = 1, .layer = @intCast(k) };
            volume += l * beadArea(0.45, 0.2);
            t += l / 30 + 0.2;
            n += 1;
        }
        t += 2;
    }
    const r = try run(gpa, &paths, params);
    return .{ r, volume * params.material.density, post_layers, count };
}

test "print sim: a slab with no support falls in strands, and later layers print on them" {
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
    // The first slab layer over air falls: on the average it sets more
    // than 0.5 mm under its place, and some of it reaches the bed. The
    // strands pile on each other: a bead does not fall through a bead.
    var over_air: usize = 0;
    var drop: f32 = 0;
    var lowest: f32 = 100;
    for (out[2]..out[2] + 9) |k| for (r.nodes(k)) |q| {
        if (@abs(q[0]) < 3) continue;
        over_air += 1;
        drop += 2.1 - q[2];
        lowest = @min(lowest, q[2]);
    };
    try testing.expect(drop / @as(f32, @floatFromInt(over_air)) > 0.5);
    try testing.expect(lowest < 0.1 + 1e-3);
    // The last layers rest on the plastic that fell before them, above
    // the bed.
    var on_mess: usize = 0;
    var last: usize = 0;
    for (out[3] - 9..out[3]) |k| for (r.nodes(k)) |q| {
        if (@abs(q[0]) < 3) continue;
        last += 1;
        if (q[2] > 0.3) on_mess += 1;
    };
    try testing.expect(on_mess * 2 > last);
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
    try testing.expectApproxEqRel(@as(f32, 3546), viscosity(p, 200), 1e-4);
    try testing.expect(viscosity(p, 180) > 2.5 * viscosity(p, 210));
    try testing.expect(viscosity(p, 61) > 1e10);
    const ts = setTemperature(p);
    try testing.expect(ts > p.material.glass_t and ts < 140);
    // The fan cools a bead many times faster than still air.
    try testing.expect(heatTransfer(p, 1, 0.28) > 4 * heatTransfer(p, 0, 0.28));
}

test "print sim: each material has its viscosity, and a type with no data gets the nearest" {
    // ABS: the WLF law of Colón Quintana: about 1540 Pa s at 240 °C.
    const a: Params = .{ .material = abs };
    try testing.expectApproxEqRel(@as(f32, 13250), viscosity(a, 200), 1e-4);
    try testing.expectApproxEqRel(@as(f32, 1540), viscosity(a, 240), 0.01);
    // ABS sets far above PLA: its glass point is 104.5 °C.
    try testing.expect(setTemperature(a) > setTemperature(.{}) + 30);
    try testing.expectEqualStrings("ABS", materialFor("abs").material.name);
    try testing.expect(materialFor("PETG").exact);
    const asa = materialFor("ASA");
    try testing.expect(!asa.exact);
    try testing.expectEqualStrings("ABS", asa.material.name);
    try testing.expectEqualStrings("PLA", materialFor("TPU").material.name);
}

test "print sim: the catenary parameter solves sinh(u) / u = r" {
    for ([_]f64{ 1 + 1e-8, 1.001, 1.2, 2, 10, 1000 }) |r| {
        const u = catenaryU(r);
        try testing.expectApproxEqRel(r, sinh(u) / u, 1e-9);
    }
}
