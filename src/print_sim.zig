//! A physical simulation of the print: the plastic leaves the nozzle, rests
//! where something holds it, hangs or falls where nothing does, cools, and
//! sets. The next layers print on the shape that formed, so a missing
//! support gives sagged bridges, drooped overhangs, and strands, as on a
//! real printer.
//!
//! - **Plastic.** Each extrusion is a chain of small masses, `spacing` mm
//!   apart along the path, each made at the time that the nozzle passes
//!   its point. A mass has a place, a speed, a temperature, and a state:
//!   solid (it does not move) or soft (it moves).
//! - **Support.** A new mass on the bed, or on solid plastic under it
//!   (within a bead height), sticks there at once: it is solid at its
//!   place. Else it is soft: it hangs from the masses next to it in its
//!   chain, and gravity pulls it.
//! - **Heat.** A soft mass cools toward the room: dT/dt = -(T - T_room) /
//!   tau, with tau shorter at more fan. Its viscosity grows as it cools (a
//!   damping that grows by e for each `visc_t` degrees below the nozzle),
//!   so a cooling strand slows, and its creep (a soft strand stretches
//!   under its weight) falls. Under the glass point it sets: it is solid
//!   where it is, and plastic after it can rest on it.
//! - **Contact.** A soft mass that touches the bed or solid plastic sticks
//!   to it while it is hotter than `stick_t` over the glass point, and is
//!   pushed out of it when it is cooler.
//! - **Solver.** Position-based dynamics (M. Müller et al., "Position Based
//!   Dynamics", 2007; see REFERENCES.md): a step moves the soft masses by
//!   their speeds and gravity, then corrects their places to keep the
//!   distance to their chain neighbors, and out of the solid plastic; the
//!   speed is the change of place. A spatial hash keeps the solid masses.
//!   The time jumps over the times with no soft mass, so a whole print
//!   costs little more than its count of masses.
//!
//! Units: mm, s, °C.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const V = [3]f32;

/// One extrusion: a polyline at a layer, printed from t0 to t1.
pub const Path = struct {
    /// The points (x, y), in mm.
    xy: []const [2]f32,
    /// The z of the top of the bead (the layer z), and the bead height
    /// and width (mm).
    z: f32,
    height: f32,
    width: f32,
    t0: f32,
    t1: f32,
    /// The fan, 0 to 1.
    fan: f32,
};

pub const Params = struct {
    nozzle_t: f32 = 210,
    room_t: f32 = 25,
    /// The glass point of the material (PLA about 60 °C).
    glass_t: f32 = 60,
    /// A soft mass hotter than glass_t + stick_t sticks on a contact.
    stick_t: f32 = 40,
    /// The cooling time (s) of a bead in still air; the fan divides it by
    /// 1 + fan_gain * fan.
    tau_still: f32 = 2.0,
    fan_gain: f32 = 5.0,
    /// The damping of a soft mass at the nozzle temperature (1/s), and the
    /// degrees for each factor e of more damping as it cools.
    damp0: f32 = 2.0,
    visc_t: f32 = 30,
    /// The creep of a soft strand at the nozzle temperature: in each step,
    /// a link keeps this share of the stretch that gravity gives it, so a
    /// hot bridge stretches under its weight and sags. It falls with the
    /// viscosity as the strand cools.
    creep0: f32 = 0.0,
    gravity: f32 = 9810,
    dt: f32 = 1.0 / 1000.0,
    iterations: u32 = 20,
};

pub const State = enum(u8) { solid, soft };

pub const Mass = struct {
    pos: V,
    prev: V,
    temp: f32,
    state: State,
    /// The mass before it in its chain, and after it, or none.
    link: u32,
    next: u32 = none,
    /// The rest distance to `link`.
    rest: f32,
    /// The bead height and width of its path.
    height: f32,
    width: f32,
    /// The place where the slicer meant it to be.
    want: V,
    /// Its path: plastic of its own path holds it only through the links
    /// of the chain, not by a contact.
    path: u32,
};

pub const none = std.math.maxInt(u32);

pub const Result = struct {
    masses: []Mass,
    /// The first mass of each path, and the end.
    path_first: []u32,
    /// The masses that set away from their place by more than half a bead
    /// height, and the largest distance (mm).
    moved: usize,
    max_move: f32,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.masses);
        gpa.free(r.path_first);
    }
};

/// A hash of the solid masses by cells of `cell` mm.
const Grid = struct {
    cell: f32,
    map: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty,

    fn key(g: *const Grid, x: f32, y: f32, z: f32) u64 {
        const ix: i64 = @intFromFloat(@floor(x / g.cell));
        const iy: i64 = @intFromFloat(@floor(y / g.cell));
        const iz: i64 = @intFromFloat(@floor(z / g.cell));
        return (@as(u64, @bitCast(ix)) & 0x1fffff) | ((@as(u64, @bitCast(iy)) & 0x1fffff) << 21) | ((@as(u64, @bitCast(iz)) & 0x1fffff) << 42);
    }

    fn put(g: *Grid, a: Allocator, p: V, i: u32) Allocator.Error!void {
        const e = try g.map.getOrPut(a, g.key(p[0], p[1], p[2]));
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(a, i);
    }

    /// Calls f(i) for each mass in the cells within r of p.
    fn near(g: *const Grid, p: V, r: f32, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32) bool) bool {
        const n: i64 = @intFromFloat(@ceil(r / g.cell));
        const cx: i64 = @intFromFloat(@floor(p[0] / g.cell));
        const cy: i64 = @intFromFloat(@floor(p[1] / g.cell));
        const cz: i64 = @intFromFloat(@floor(p[2] / g.cell));
        var dz = -n;
        while (dz <= n) : (dz += 1) {
            var dy = -n;
            while (dy <= n) : (dy += 1) {
                var dx = -n;
                while (dx <= n) : (dx += 1) {
                    const k = (@as(u64, @bitCast(cx + dx)) & 0x1fffff) | ((@as(u64, @bitCast(cy + dy)) & 0x1fffff) << 21) | ((@as(u64, @bitCast(cz + dz)) & 0x1fffff) << 42);
                    const list = g.map.get(k) orelse continue;
                    for (list.items) |i| if (f(ctx, i)) return true;
                }
            }
        }
        return false;
    }
};

fn sub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn dist(a: V, b: V) f32 {
    const d = sub(a, b);
    return @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
}

const Sim = struct {
    gpa: Allocator,
    p: Params,
    masses: std.ArrayList(Mass) = .empty,
    soft: std.ArrayList(u32) = .empty,
    grid: Grid,
    arena: std.heap.ArenaAllocator,
    time: f32 = 0,
    /// The newest mass of the path that prints now: the nozzle holds it at
    /// its place until the next mass comes out, so the strand stays tight
    /// between what holds it and the nozzle (a bridge).
    head: u32 = none,

    /// True if a mass at p of bead height h rests on the bed or on solid
    /// plastic.
    fn held(s: *Sim, p: V, h: f32, w: f32, path: u32) bool {
        // The center of a bead is h / 2 under its top.
        if (p[2] - 0.5 * h <= 0.01) return true;
        const Ctx = struct { s: *Sim, p: V, h: f32, w: f32, path: u32 };
        return s.grid.near(p, @max(w, h) * 1.2, Ctx{ .s = s, .p = p, .h = h, .w = w, .path = path }, struct {
            fn f(c: Ctx, i: u32) bool {
                if (c.s.masses.items[i].path == c.path) return false;
                const q = c.s.masses.items[i].pos;
                const dz = c.p[2] - q[2];
                if (dz < -0.25 * c.h or dz > 1.3 * c.h) return false;
                const dx = c.p[0] - q[0];
                const dy = c.p[1] - q[1];
                // Under it within the bead width: it rests on it.
                return dx * dx + dy * dy < 0.36 * c.w * c.w;
            }
        }.f);
    }

    fn setSolid(s: *Sim, i: u32) Allocator.Error!void {
        const m = &s.masses.items[i];
        m.state = .solid;
        m.prev = m.pos;
        try s.grid.put(s.arena.allocator(), m.pos, i);
    }

    fn emit(s: *Sim, pos: V, link: u32, rest: f32, h: f32, w: f32, path: u32) Allocator.Error!u32 {
        const i: u32 = @intCast(s.masses.items.len);
        if (link != none) s.masses.items[link].next = i;
        try s.masses.append(s.gpa, .{ .pos = pos, .prev = pos, .temp = s.p.nozzle_t, .state = .soft, .link = link, .rest = rest, .height = h, .width = w, .want = pos, .path = path });
        if (s.held(pos, h, w, path)) {
            try s.setSolid(i);
        } else try s.soft.append(s.gpa, i);
        return i;
    }

    /// Runs the soft masses until time t (or until none is soft).
    fn runTo(s: *Sim, t: f32, fan: f32) Allocator.Error!void {
        const p = s.p;
        const tau = p.tau_still / (1 + p.fan_gain * fan);
        while (s.time < t and s.soft.items.len > 0) {
            const dt = @min(p.dt, t - s.time);
            s.time += dt;
            // Move by the speed and gravity, with the damping of the
            // viscosity.
            for (s.soft.items) |i| {
                const m = &s.masses.items[i];
                const damp = p.damp0 * @exp((p.nozzle_t - m.temp) / p.visc_t);
                const keep = @exp(-damp * dt);
                const v = sub(m.pos, m.prev);
                m.prev = m.pos;
                m.pos = .{ m.pos[0] + v[0] * keep, m.pos[1] + v[1] * keep, m.pos[2] + v[2] * keep - p.gravity * dt * dt };
                m.temp = p.room_t + (m.temp - p.room_t) * @exp(-dt / tau);
            }
            // The creep: the stretch that gravity gives a soft link in this
            // step is the load on it; the hot plastic flows under it, and
            // the link keeps part of the stretch.
            for (s.soft.items) |i| {
                const m = &s.masses.items[i];
                if (m.link == none) continue;
                const l = dist(m.pos, s.masses.items[m.link].pos);
                if (l > m.rest) m.rest += (l - m.rest) * @min(p.creep0 * @exp(-(p.nozzle_t - m.temp) / p.visc_t), 1);
            }
            // Keep the chains together, and out of the bed and the solid
            // plastic.
            for (0..p.iterations) |_| {
                for (s.soft.items) |i| {
                    const m = &s.masses.items[i];
                    if (m.link != none) s.keepLink(i, m.link, dt / @as(f32, @floatFromInt(p.iterations)));
                    s.attach(i);
                    if (i == s.head) m.pos = m.want;
                    // The next mass of the chain, if soft, links back to
                    // this one: its own pass corrects it.
                    if (m.pos[2] - 0.5 * m.height < 0) m.pos[2] = 0.5 * m.height;
                }
            }
            // Contacts and setting.
            var k: usize = 0;
            while (k < s.soft.items.len) {
                const i = s.soft.items[k];
                const m = &s.masses.items[i];
                const hot = m.temp > p.glass_t + p.stick_t;
                const touches = m.pos[2] - 0.5 * m.height <= 0.01 or s.touchesSolid(i);
                if (m.temp < p.glass_t or (touches and hot)) {
                    try s.setSolid(i);
                    _ = s.soft.swapRemove(k);
                    continue;
                }
                k += 1;
            }
        }
        if (s.soft.items.len == 0) s.time = @max(s.time, t);
    }

    fn keepLink(s: *Sim, i: u32, j: u32, dt: f32) void {
        const a = &s.masses.items[i];
        const b = &s.masses.items[j];
        const d = sub(a.pos, b.pos);
        const l = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        if (l < 1e-6) return;
        _ = dt;
        const err = (l - a.rest) / l;
        if (b.state == .solid) {
            a.pos = .{ a.pos[0] - d[0] * err, a.pos[1] - d[1] * err, a.pos[2] - d[2] * err };
        } else {
            const h = 0.5 * err;
            a.pos = .{ a.pos[0] - d[0] * h, a.pos[1] - d[1] * h, a.pos[2] - d[2] * h };
            b.pos = .{ b.pos[0] + d[0] * h, b.pos[1] + d[1] * h, b.pos[2] + d[2] * h };
        }
    }

    /// The long-range attachments (Kim, Chentanez, Müller 2012): a soft mass
    /// is no farther from the nearest held mass on each side of its chain
    /// (a solid mass, or the mass at the nozzle) than the chain length
    /// between them. So a long strand does not stretch past its length in
    /// one step, with few passes.
    fn attach(s: *Sim, i: u32) void {
        const ms = s.masses.items;
        inline for (.{ true, false }) |back| {
            var j = i;
            var arc: f32 = 0;
            var k: usize = 0;
            while (k < 4096) : (k += 1) {
                const nx = if (back) ms[j].link else ms[j].next;
                if (nx == none) break;
                arc += if (back) ms[j].rest else ms[nx].rest;
                j = nx;
                if (ms[j].state == .solid or j == s.head) break;
            }
            if (j != i and (ms[j].state == .solid or j == s.head)) {
                const d = sub(ms[i].pos, ms[j].pos);
                const l = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
                if (l > arc and l > 1e-6) {
                    const f = arc / l;
                    ms[i].pos = .{ ms[j].pos[0] + d[0] * f, ms[j].pos[1] + d[1] * f, ms[j].pos[2] + d[2] * f };
                }
            }
        }
    }

    fn touchesSolid(s: *Sim, i: u32) bool {
        const m = s.masses.items[i];
        const Ctx = struct { s: *Sim, i: u32, m: Mass };
        return s.grid.near(m.pos, @max(m.width, m.height), Ctx{ .s = s, .i = i, .m = m }, struct {
            fn f(c: Ctx, j: u32) bool {
                const q = c.s.masses.items[j];
                if (q.path == c.m.path) return false;
                const dz = c.m.pos[2] - q.pos[2];
                const dx = c.m.pos[0] - q.pos[0];
                const dy = c.m.pos[1] - q.pos[1];
                // Under it or beside it, within a bead.
                return dz > -0.25 * c.m.height and dz < 1.05 * c.m.height and dx * dx + dy * dy < 0.36 * c.m.width * c.m.width;
            }
        }.f);
    }
};

/// Simulates the paths in their order of print.
pub fn run(gpa: Allocator, paths: []const Path, params: Params) Allocator.Error!Result {
    var s: Sim = .{ .gpa = gpa, .p = params, .grid = .{ .cell = 0.5 }, .arena = .init(gpa) };
    defer s.arena.deinit();
    defer s.soft.deinit(gpa);
    errdefer s.masses.deinit(gpa);
    var firsts = try gpa.alloc(u32, paths.len + 1);
    errdefer gpa.free(firsts);
    for (paths, 0..) |path, pi| {
        firsts[pi] = @intCast(s.masses.items.len);
        // The nozzle leaves the last path: its end hangs free.
        s.head = none;
        if (path.xy.len < 2) continue;
        const spacing = @max(0.5 * path.width, 0.15);
        // The length of the path, for the time of each mass.
        var total: f32 = 0;
        for (path.xy[1..], path.xy[0 .. path.xy.len - 1]) |b, a| total += @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
        if (total <= 0) continue;
        const zc = path.z - 0.5 * path.height;
        var last: u32 = none;
        var along: f32 = 0;
        var next: f32 = 0;
        for (path.xy[1..], path.xy[0 .. path.xy.len - 1]) |b, a| {
            const seg = @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
            while (next <= along + seg) : (next += spacing) {
                const u = if (seg > 0) (next - along) / seg else 0;
                const pos = V{ a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u, zc };
                const t = path.t0 + (path.t1 - path.t0) * (next / total);
                try s.runTo(t, path.fan);
                last = try s.emit(pos, last, spacing, path.height, path.width, @intCast(pi));
                s.head = last;
            }
            along += seg;
        }
    }
    firsts[paths.len] = @intCast(s.masses.items.len);
    s.head = none;
    // The last soft masses set.
    try s.runTo(s.time + 60, if (paths.len > 0) paths[paths.len - 1].fan else 0);
    var moved: usize = 0;
    var max_move: f32 = 0;
    for (s.masses.items) |m| {
        const d = dist(m.pos, m.want);
        max_move = @max(max_move, d);
        if (d > 0.5 * m.height) moved += 1;
    }
    return .{ .masses = try s.masses.toOwnedSlice(gpa), .path_first = firsts, .moved = moved, .max_move = max_move };
}

const testing = std.testing;

/// A straight line from a to b at layer z.
fn line(a: [2]f32, b: [2]f32, z: f32, t0: f32, fan: f32, pts: *[2][2]f32) Path {
    pts.* = .{ a, b };
    const l = @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
    return .{ .xy = pts, .z = z, .height = 0.2, .width = 0.45, .t0 = t0, .t1 = t0 + l / 40, .fan = fan };
}

test "print sim: a wall of lines on lines stays where it prints" {
    const gpa = testing.allocator;
    var pts: [10][2][2]f32 = undefined;
    var paths: [10]Path = undefined;
    for (0..10) |k| paths[k] = line(.{ 0, 0 }, .{ 20, 0 }, 0.2 * @as(f32, @floatFromInt(k + 1)), 2 * @as(f32, @floatFromInt(k)), 1, &pts[k]);
    var r = try run(gpa, &paths, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.moved);
    try testing.expect(r.max_move < 1e-3);
}

/// Two posts 20 mm apart, 10 layers high, then a bridge over them.
fn bridgeSag(gpa: Allocator, fan: f32) !f32 {
    var pts: [21][2][2]f32 = undefined;
    var paths: [21]Path = undefined;
    var n: usize = 0;
    for (0..10) |k| {
        const z = 0.2 * @as(f32, @floatFromInt(k + 1));
        const t = 4 * @as(f32, @floatFromInt(k));
        paths[n] = line(.{ 0, 0 }, .{ 0, 3 }, z, t, 1, &pts[n]);
        n += 1;
        paths[n] = line(.{ 20, 3 }, .{ 20, 0 }, z, t + 1, 1, &pts[n]);
        n += 1;
    }
    // The bridge, a bit past each post so its ends rest on them.
    pts[n] = .{ .{ -0.2, 1.5 }, .{ 20.2, 1.5 } };
    paths[n] = .{ .xy = &pts[n], .z = 2.2, .height = 0.2, .width = 0.45, .t0 = 41, .t1 = 41 + 20.4 / 15.0, .fan = fan };
    n += 1;
    var r = try run(gpa, paths[0..n], .{});
    defer r.deinit(gpa);
    // The sag: the lowest place of the bridge under its want.
    var sag: f32 = 0;
    for (r.masses[r.path_first[n - 1]..r.path_first[n]]) |m| sag = @max(sag, m.want[2] - m.pos[2]);
    return sag;
}

test "print sim: a bridge sags, and less at full fan than with no fan" {
    const gpa = testing.allocator;
    const full = try bridgeSag(gpa, 1);
    const off = try bridgeSag(gpa, 0);
    try testing.expect(full > 0.05);
    try testing.expect(off > full);
    // A bridge does not fall to the bed: its chain hangs from the posts.
    try testing.expect(off < 2.0);
}

test "print sim: a line over air with nothing under it falls to the bed" {
    const gpa = testing.allocator;
    var pts: [2][2]f32 = undefined;
    // A line at 5 mm with no plastic under it: it falls and lands on the
    // bed, away from its place.
    var paths = [_]Path{line(.{ 0, 0 }, .{ 10, 0 }, 5, 0, 0, &pts)};
    var r = try run(gpa, &paths, .{});
    defer r.deinit(gpa);
    try testing.expect(r.moved > 0);
    var lowest: f32 = 100;
    for (r.masses) |m| lowest = @min(lowest, m.pos[2]);
    try testing.expect(lowest < 0.2);
}
