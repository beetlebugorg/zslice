//! The motion planner: the time of each move of a layer, with the
//! acceleration of the printer.
//!
//! A printer does not move at the speed of the G-code at once. Each move
//! starts at the speed of the junction with the move before it, goes up to
//! its speed (or less) with the acceleration, and goes down to the speed of
//! the junction with the next move. The firmware plans the speeds with a
//! look-ahead over the moves in its buffer. This module plans them the
//! same way, so that the time estimate is the time of the print:
//!
//! A move can have a Z part (slope smoothing, see layer.zig). Its
//! direction is then a unit vector in 3D, and its length is the 3D
//! length. The emitter limits its speed and acceleration so that the Z
//! axis stays within `max_z_speed` and `max_z_accel`.
//!
//! 1. Junction speed. Two moves at an angle meet on a small arc. The arc
//!    is as large as a 90 degree corner at `corner_speed` (the square
//!    corner velocity of Klipper, the "junction deviation" of grbl and
//!    Marlin). With the half angle h between the moves (h = 0 for a
//!    reversal), the speed is at most v^2 = R * corner_speed^2 *
//!    (sqrt(2) - 1), with R = sin h / (1 - sin h). A straight junction has
//!    no limit, a 90 degree corner gives v = corner_speed, and a reversal
//!    stops. The arc also must not go past the middle of each move: v^2 <=
//!    a * d / 2 * tan h. A change of the flow (a travel that goes into an
//!    extrusion) is limited by the speed change of the filament that the
//!    extruder takes with no stop: v <= extruder_corner_speed / (change of
//!    filament mm per mm of move).
//! 2. A pass forward and a pass backward: no move can change v^2 by more
//!    than 2 * a * d. The layer starts and ends at rest, and so does each
//!    move after a stop (a retraction or a Z move).
//! 3. The cruise speed. With `min_cruise_ratio` (Klipper), a group of moves
//!    that goes up and down again (a "hill") has a peak speed from a
//!    smaller acceleration, a * (1 - ratio). This gives short moves some
//!    time at a constant speed. The peak comes from the same passes with
//!    the smaller acceleration. Each move of the hill cruises at most at
//!    the peak.
//! 4. The time of each move: a trapezoid of speed, from the start speed up
//!    to the cruise speed and down to the end speed.
//!
//! References (see REFERENCES.md): the junction deviation of grbl (Sonny
//! Jeon), and the look-ahead and the minimum cruise ratio as Klipper
//! documents them (docs/Kinematics.md).

const std = @import("std");
const fmin = @import("geom.zig").fmin;
const fmax = @import("geom.zig").fmax;

pub const Limits = struct {
    /// The speed at a 90 degree corner, in mm/s.
    corner_speed: f64,
    /// See the file comment, step 3. 0: no limit.
    min_cruise_ratio: f64 = 0,
    /// The change of the filament speed (mm/s) at a junction that the
    /// extruder takes with no stop (instantaneous_corner_velocity of
    /// Klipper).
    extruder_corner_speed: f64 = 1,
};

pub const Move = struct {
    /// The direction of the move: a unit vector in X, Y, and Z, with the
    /// Z part in `dir_z`. A move in one layer has `dir_z` = 0.
    dir: [2]f64,
    dir_z: f64 = 0,
    /// The length (mm, in X, Y, and Z), the speed (mm/s), and the
    /// acceleration (mm/s²).
    len: f64,
    speed: f64,
    accel: f64,
    /// The filament length for each mm of the move (0 for a travel).
    e_ratio: f64 = 0,
    /// The move starts at rest: a retraction or a Z move is before it.
    stop_before: bool = false,
    /// The result: the time of the move, in seconds.
    time: f64 = 0,

    // The work values of `plan`, in (mm/s)^2.
    max_start: f64 = 0,
    max_smooth: f64 = 0,
    start: f64 = 0,
    end: f64 = 0,
};

/// Plans the moves, which start and end at rest, and sets the time of each.
/// Returns the sum of the times.
pub fn plan(moves: []Move, limits: Limits) f64 {
    const jd_v2 = limits.corner_speed * limits.corner_speed * (std.math.sqrt2 - 1);
    const smooth = 1 - std.math.clamp(limits.min_cruise_ratio, 0, 0.99);
    // Step 1, and the forward pass of step 2 on the limits.
    for (moves, 0..) |*m, i| {
        if (i == 0 or m.stop_before) {
            m.max_start = 0;
            m.max_smooth = 0;
            continue;
        }
        const p = &moves[i - 1];
        const v2 = m.speed * m.speed;
        const pv2 = p.speed * p.speed;
        var ms = fmin(fmin(v2, pv2), p.max_start + 2 * p.accel * p.len);
        const dr = @abs(m.e_ratio - p.e_ratio);
        if (dr > 0) {
            const ve = limits.extruder_corner_speed / dr;
            ms = fmin(ms, ve * ve);
        }
        // The cosine of the angle between the reversed first move and the
        // second move. 1: a reversal. -1: straight on.
        const cos = -(m.dir[0] * p.dir[0] + m.dir[1] * p.dir[1] + m.dir_z * p.dir_z);
        const sin_h = @sqrt(fmax(0.5 * (1 - cos), 0));
        const cos_h = @sqrt(fmax(0.5 * (1 + cos), 0));
        if (1 - sin_h > 0 and cos_h > 0) {
            const r = sin_h / (1 - sin_h);
            const tan_q = 0.25 * sin_h / cos_h;
            ms = fmin(fmin(ms, r * jd_v2), fmin(2 * m.accel * m.len * tan_q, 2 * p.accel * p.len * tan_q));
        }
        m.max_start = ms;
        m.max_smooth = fmin(ms, p.max_smooth + 2 * p.accel * smooth * p.len);
    }
    // The backward pass of step 2, and step 3. The moves of a hill after
    // its peak (in print order) wait in `pending` (the moves from i + 1 to
    // pend_end) until the peak is known.
    var next_end: f64 = 0;
    var next_smooth: f64 = 0;
    var peak: f64 = 0;
    var pend_end: usize = moves.len;
    var i = moves.len;
    while (i > 0) {
        i -= 1;
        const m = &moves[i];
        const v2 = m.speed * m.speed;
        const delta = 2 * m.accel * m.len;
        const reach = next_end + delta;
        const start = fmin(m.max_start, reach);
        const reach_smooth = next_smooth + delta * smooth;
        const sm = fmin(m.max_smooth, reach_smooth);
        m.start = start;
        m.end = next_end;
        if (sm < reach_smooth) {
            // The move can speed up. If it can also slow down, or moves
            // after it slow down, it is the top of a hill.
            if (sm + delta * smooth > next_smooth or pend_end > i + 1) {
                peak = fmin(v2, (sm + reach_smooth) * 0.5);
                var cruise = peak;
                for (moves[i + 1 .. pend_end]) |*q| {
                    cruise = fmin(cruise, q.start);
                    setTime(q, fmin(q.start, cruise), cruise, fmin(q.end, cruise));
                }
                pend_end = i + 1;
            }
            const cruise = fmin(fmin((start + reach) * 0.5, v2), peak);
            setTime(m, fmin(start, cruise), cruise, fmin(next_end, cruise));
            pend_end = i;
        }
        next_end = start;
        next_smooth = sm;
    }
    // Moves that never found a peak (not possible with a ratio below 1).
    for (moves[0..pend_end]) |*q| {
        const cruise = fmin(q.speed * q.speed, q.start);
        setTime(q, fmin(q.start, cruise), cruise, fmin(q.end, cruise));
    }
    var total: f64 = 0;
    for (moves) |m| total += m.time;
    return total;
}

/// The time of a move with the squared speeds at its start, while it
/// cruises, and at its end.
fn setTime(m: *Move, start: f64, cruise: f64, end: f64) void {
    if (!(cruise > 0)) {
        m.time = 0;
        return;
    }
    const half_inv = 0.5 / m.accel;
    const accel_d = (cruise - start) * half_inv;
    const decel_d = (cruise - end) * half_inv;
    const cruise_d = fmax(m.len - accel_d - decel_d, 0);
    const sv = @sqrt(start);
    const cv = @sqrt(cruise);
    const ev = @sqrt(end);
    m.time = accel_d / ((sv + cv) * 0.5) + cruise_d / cv + decel_d / ((ev + cv) * 0.5);
}

/// The time of a move from rest to rest: a trapezoid of speed, or a
/// triangle if the move is too short to reach the speed.
pub fn restTime(len: f64, speed: f64, accel: f64) f64 {
    if (!(len > 0) or !(speed > 0)) return 0;
    if (!(accel > 0)) return len / speed;
    const d_acc = speed * speed / accel;
    if (d_acc <= len) return len / speed + speed / accel;
    return 2 * @sqrt(len / accel);
}

const testing = std.testing;

fn line(dx: f64, dy: f64, speed: f64, accel: f64) Move {
    const d = @sqrt(dx * dx + dy * dy);
    return .{ .dir = .{ dx / d, dy / d }, .len = d, .speed = speed, .accel = accel };
}

test "one move: up to speed, cruise, and down" {
    // 100 mm at 100 mm/s with 1000 mm/s²: 5 mm and 0.1 s to speed up, the
    // same to stop, and 90 mm at full speed.
    var moves = [_]Move{line(100, 0, 100, 1000)};
    try testing.expectApproxEqAbs(@as(f64, 1.1), plan(&moves, .{ .corner_speed = 5 }), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.1), restTime(100, 100, 1000), 1e-9);
}

test "two moves in a line take the time of one" {
    var moves = [_]Move{ line(50, 0, 100, 1000), line(50, 0, 100, 1000) };
    try testing.expectApproxEqAbs(@as(f64, 1.1), plan(&moves, .{ .corner_speed = 5 }), 1e-9);
}

test "a corner slows down, a reversal stops" {
    var corner = [_]Move{ line(100, 0, 100, 1000), line(0, 100, 100, 1000) };
    var back = [_]Move{ line(100, 0, 100, 1000), line(-100, 0, 100, 1000) };
    const t_corner = plan(&corner, .{ .corner_speed = 5 });
    const t_back = plan(&back, .{ .corner_speed = 5 });
    try testing.expect(t_corner > 2.1 and t_corner < 2.2);
    try testing.expectApproxEqAbs(@as(f64, 2.2), t_back, 1e-9);
    // At a 90 degree corner the speed is the corner speed.
    try testing.expectApproxEqAbs(@as(f64, 25), corner[1].start, 1e-6);
}

test "the minimum cruise ratio limits the peak of a short move" {
    // 10 mm from rest to rest with 1000 mm/s²: a triangle up to 100 mm/s
    // takes 0.2 s. With the ratio 0.5, the peak is sqrt(a d / 2) and the
    // move cruises at it for a time.
    var a = [_]Move{line(10, 0, 200, 1000)};
    var b = [_]Move{line(10, 0, 200, 1000)};
    try testing.expectApproxEqAbs(@as(f64, 0.2), plan(&a, .{ .corner_speed = 5 }), 1e-9);
    const vp: f64 = @sqrt(1000.0 * 10 / 2);
    const want = 2 * vp / 1000 + (10 - vp * vp / 1000) / vp;
    try testing.expectApproxEqAbs(want, plan(&b, .{ .corner_speed = 5, .min_cruise_ratio = 0.5 }), 1e-9);
}

test "a move with a Z part: the junction angle is in 3D" {
    // Two moves that turn only in Z: a small angle, so the junction is
    // almost straight and the corner speed limit is high.
    const k: f64 = 1.0 / @sqrt(1.01);
    var moves = [_]Move{
        .{ .dir = .{ k, 0 }, .dir_z = 0.1 * k, .len = 10, .speed = 50, .accel = 1000 },
        .{ .dir = .{ k, 0 }, .dir_z = -0.1 * k, .len = 10, .speed = 50, .accel = 1000 },
    };
    _ = plan(&moves, .{ .corner_speed = 5 });
    // The same moves with no Z part go straight on at full speed.
    var flat = [_]Move{ line(10, 0, 50, 1000), line(10, 0, 50, 1000) };
    _ = plan(&flat, .{ .corner_speed = 5 });
    try testing.expect(moves[1].start < flat[1].start);
    try testing.expect(moves[1].start > 25 * 25);
}

test "a stop before a move" {
    var moves = [_]Move{ line(50, 0, 100, 1000), line(50, 0, 100, 1000) };
    moves[1].stop_before = true;
    try testing.expectApproxEqAbs(@as(f64, 2 * restTime(50, 100, 1000)), plan(&moves, .{ .corner_speed = 5 }), 1e-9);
}
