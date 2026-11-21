//! Number types for the robust Voronoi predicates.
//!
//! The Voronoi builder (`src/voronoi.zig`) must decide the order of events
//! and the position of circle centers without mistakes. Plain doubles are
//! fast, but they round. This file gives the tools that find when a double
//! result can be wrong, and an exact path for these cases:
//!
//! - `ulpCmp` compares two doubles with a tolerance in units in the last
//!   place (ULP). It maps the bit patterns of the doubles to a monotone
//!   integer line and compares the distance.
//! - `RobustFpt` is a double with a bound of its relative error, in ULPs.
//!   Each operation adds to the bound. A sum of values with opposite signs
//!   can lose all precision, so `RobustDif` keeps the positive and the
//!   negative parts apart and subtracts them only at the end.
//! - `ExtendedInt` is a signed integer of up to 64 chunks of 32 bits. The
//!   exact path uses it for products of the input coordinates.
//! - `Efpt` is a double with an extra exponent. It holds the very large
//!   values of the exact path without overflow.
//! - `SqrtExpr` evaluates sums of the form A0 * sqrt(B0) + A1 * sqrt(B1) + ...
//!   with a small relative error. When two terms have opposite signs, it
//!   multiplies by the conjugate, so that no subtraction of near equal values
//!   happens.
//!
//! This file is a port to Zig of boost::polygon `detail/voronoi_ctypes.hpp`
//! and `detail/voronoi_robust_fpt.hpp` (https://github.com/boostorg/polygon,
//! commit ddb9c8adadbbb539fe52cb7f8ee0a446ba5ead04).
//!
//! Copyright Andrii Sydorchuk 2010-2012.
//! Distributed under the Boost Software License, Version 1.0. See
//! licenses/boost-BSL-1.0.txt and docs/references/libraries.md.

const std = @import("std");

pub const UlpResult = enum { less, equal, more };

/// Compares two doubles. They are equal when they are at most `max_ulps`
/// representable doubles apart.
pub fn ulpCmp(a: f64, b: f64, max_ulps: u64) UlpResult {
    var ll_a: u64 = @bitCast(a);
    var ll_b: u64 = @bitCast(b);
    const sign: u64 = 0x8000000000000000;
    if (ll_a < sign) ll_a = sign -% ll_a;
    if (ll_b < sign) ll_b = sign -% ll_b;
    if (ll_a > ll_b) return if (ll_a - ll_b <= max_ulps) .equal else .less;
    return if (ll_b - ll_a <= max_ulps) .equal else .more;
}

// ---------------------------------------------------------------------------
// Extended exponent floating point.

const max_significant_exp_dif: i32 = 54;

pub const Efpt = struct {
    val: f64,
    exp: i32,

    pub fn init(v: f64) Efpt {
        const f = std.math.frexp(v);
        return .{ .val = f.significand, .exp = f.exponent };
    }

    pub fn initExp(v: f64, e: i32) Efpt {
        const f = std.math.frexp(v);
        return .{ .val = f.significand, .exp = f.exponent + e };
    }

    pub fn isPos(a: Efpt) bool {
        return a.val > 0;
    }
    pub fn isNeg(a: Efpt) bool {
        return a.val < 0;
    }
    pub fn isZero(a: Efpt) bool {
        return a.val == 0;
    }

    pub fn neg(a: Efpt) Efpt {
        return initExp(-a.val, a.exp);
    }

    pub fn add(a: Efpt, b: Efpt) Efpt {
        if (a.val == 0.0 or b.exp > a.exp + max_significant_exp_dif) return b;
        if (b.val == 0.0 or a.exp > b.exp + max_significant_exp_dif) return a;
        if (a.exp >= b.exp) {
            const ed = a.exp - b.exp;
            return initExp(std.math.ldexp(a.val, ed) + b.val, b.exp);
        } else {
            const ed = b.exp - a.exp;
            return initExp(std.math.ldexp(b.val, ed) + a.val, a.exp);
        }
    }

    pub fn sub(a: Efpt, b: Efpt) Efpt {
        if (a.val == 0.0 or b.exp > a.exp + max_significant_exp_dif) return initExp(-b.val, b.exp);
        if (b.val == 0.0 or a.exp > b.exp + max_significant_exp_dif) return a;
        if (a.exp >= b.exp) {
            const ed = a.exp - b.exp;
            return initExp(std.math.ldexp(a.val, ed) - b.val, b.exp);
        } else {
            const ed = b.exp - a.exp;
            return initExp(std.math.ldexp(-b.val, ed) + a.val, a.exp);
        }
    }

    pub fn mul(a: Efpt, b: Efpt) Efpt {
        return initExp(a.val * b.val, a.exp + b.exp);
    }

    pub fn div(a: Efpt, b: Efpt) Efpt {
        return initExp(a.val / b.val, a.exp - b.exp);
    }

    pub fn sqrt(a: Efpt) Efpt {
        var v = a.val;
        var e = a.exp;
        if (e & 1 != 0) {
            v *= 2.0;
            e -= 1;
        }
        return initExp(@sqrt(v), e >> 1);
    }

    /// The value as a plain double.
    pub fn d(a: Efpt) f64 {
        return std.math.ldexp(a.val, a.exp);
    }
};

// ---------------------------------------------------------------------------
// Extended integer: up to `N` chunks of 32 bits and a sign.
//
// Boost uses 64 chunks. A copy of 64 chunks is slow, and most values need
// far fewer. So the type is generic in `N`, and each value has an overflow
// flag. An operation sets the flag when its result needs more than `N`
// chunks (where the boost code drops the high chunks). Below `N` chunks,
// the results are the same for each `N`. The predicates first use a small
// `N`, and use 64 chunks again only when a flag is set. So the results are
// the same as with 64 chunks.

pub const big_chunks = 64;

pub const ExtendedInt = ExtendedIntN(big_chunks);

pub fn ExtendedIntN(comptime N: usize) type {
    return struct {
        chunks: [N]u32 = undefined,
        /// The number of used chunks. The sign is the sign of the value.
        count: i32 = 0,
        /// The value needed more than N chunks somewhere on its way.
        ovf: bool = false,

        const Self = @This();

        pub fn from(v: i64) Self {
            var r: Self = .{};
            if (v > 0) {
                const u: u64 = @intCast(v);
                r.chunks[0] = @truncate(u);
                r.chunks[1] = @truncate(u >> 32);
                r.count = if (r.chunks[1] != 0) 2 else 1;
            } else if (v < 0) {
                const u: u64 = @intCast(-v);
                r.chunks[0] = @truncate(u);
                r.chunks[1] = @truncate(u >> 32);
                r.count = if (r.chunks[1] != 0) -2 else -1;
            }
            return r;
        }

        pub fn size(a: *const Self) usize {
            return @abs(a.count);
        }
        pub fn isPos(a: *const Self) bool {
            return a.count > 0;
        }
        pub fn isNeg(a: *const Self) bool {
            return a.count < 0;
        }
        pub fn isZero(a: *const Self) bool {
            return a.count == 0;
        }

        pub fn neg(a: Self) Self {
            var r = a;
            r.count = -r.count;
            return r;
        }

        pub fn add(e1: Self, e2: Self) Self {
            if (e1.count == 0) return e2.withOvf(e1.ovf);
            if (e2.count == 0) return e1.withOvf(e2.ovf);
            var r: Self = .{ .ovf = e1.ovf or e2.ovf };
            if ((e1.count > 0) != (e2.count > 0)) {
                r.difChunks(e1.chunks[0..e1.size()], e2.chunks[0..e2.size()], false);
            } else {
                r.addChunks(e1.chunks[0..e1.size()], e2.chunks[0..e2.size()]);
            }
            if (e1.count < 0) r.count = -r.count;
            return r;
        }

        pub fn sub(e1: Self, e2: Self) Self {
            if (e1.count == 0) return e2.neg().withOvf(e1.ovf);
            if (e2.count == 0) return e1.withOvf(e2.ovf);
            var r: Self = .{ .ovf = e1.ovf or e2.ovf };
            if ((e1.count > 0) != (e2.count > 0)) {
                r.addChunks(e1.chunks[0..e1.size()], e2.chunks[0..e2.size()]);
            } else {
                r.difChunks(e1.chunks[0..e1.size()], e2.chunks[0..e2.size()], false);
            }
            if (e1.count < 0) r.count = -r.count;
            return r;
        }

        pub fn mul(e1: Self, e2: Self) Self {
            var r: Self = .{ .ovf = e1.ovf or e2.ovf };
            if (e1.count == 0 or e2.count == 0) return r;
            r.mulChunks(e1.chunks[0..e1.size()], e2.chunks[0..e2.size()]);
            if ((e1.count > 0) != (e2.count > 0)) r.count = -r.count;
            return r;
        }

        pub fn muli(e1: Self, v: i64) Self {
            return mul(e1, from(v));
        }

        fn withOvf(a: Self, o: bool) Self {
            var r = a;
            r.ovf = r.ovf or o;
            return r;
        }

        /// The value as mantissa and binary exponent: value = first * 2^second.
        pub fn p(a: *const Self) struct { f64, i32 } {
            var first: f64 = 0;
            var second: i32 = 0;
            const sz = a.size();
            if (sz == 0) return .{ 0, 0 };
            if (sz == 1) {
                first = @floatFromInt(a.chunks[0]);
            } else if (sz == 2) {
                first = @as(f64, @floatFromInt(a.chunks[1])) * 4294967296.0 + @as(f64, @floatFromInt(a.chunks[0]));
            } else {
                var i: usize = 1;
                while (i <= 3) : (i += 1) {
                    first *= 4294967296.0;
                    first += @floatFromInt(a.chunks[sz - i]);
                }
                second = @intCast((sz - 3) << 5);
            }
            if (a.count < 0) first = -first;
            return .{ first, second };
        }

        pub fn d(a: *const Self) f64 {
            const pr = a.p();
            return std.math.ldexp(pr[0], pr[1]);
        }

        pub fn toEfpt(a: *const Self) Efpt {
            const pr = a.p();
            return Efpt.initExp(pr[0], pr[1]);
        }

        fn addChunks(r: *Self, c1_in: []const u32, c2_in: []const u32) void {
            var c1 = c1_in;
            var c2 = c2_in;
            if (c1.len < c2.len) {
                const t = c1;
                c1 = c2;
                c2 = t;
            }
            r.count = @intCast(c1.len);
            var temp: u64 = 0;
            for (0..c2.len) |i| {
                temp += @as(u64, c1[i]) + @as(u64, c2[i]);
                r.chunks[i] = @truncate(temp);
                temp >>= 32;
            }
            for (c2.len..c1.len) |i| {
                temp += @as(u64, c1[i]);
                r.chunks[i] = @truncate(temp);
                temp >>= 32;
            }
            if (temp != 0) {
                if (r.count != N) {
                    r.chunks[@intCast(r.count)] = @truncate(temp);
                    r.count += 1;
                } else {
                    r.ovf = true;
                }
            }
        }

        fn difChunks(r: *Self, c1: []const u32, c2: []const u32, rec: bool) void {
            var sz1 = c1.len;
            var sz2 = c2.len;
            if (sz1 < sz2) {
                r.difChunks(c2, c1, true);
                r.count = -r.count;
                return;
            } else if (sz1 == sz2 and !rec) {
                while (true) {
                    sz1 -= 1;
                    if (c1[sz1] < c2[sz1]) {
                        sz1 += 1;
                        r.difChunks(c2[0..sz1], c1[0..sz1], true);
                        r.count = -r.count;
                        return;
                    } else if (c1[sz1] > c2[sz1]) {
                        sz1 += 1;
                        break;
                    }
                    if (sz1 == 0) break;
                }
                if (sz1 == 0) {
                    r.count = 0;
                    return;
                }
                sz2 = sz1;
            }
            r.count = @intCast(sz1 - 1);
            var flag = false;
            for (0..sz2) |i| {
                r.chunks[i] = c1[i] -% c2[i] -% @as(u32, if (flag) 1 else 0);
                flag = (c1[i] < c2[i]) or (c1[i] == c2[i] and flag);
            }
            for (sz2..sz1) |i| {
                r.chunks[i] = c1[i] -% @as(u32, if (flag) 1 else 0);
                flag = c1[i] == 0 and flag;
            }
            if (r.chunks[@intCast(r.count)] != 0) r.count += 1;
        }

        /// The product of two magnitudes. Boost sums the partial products
        /// of each output chunk. This schoolbook loop gives the same exact
        /// chunks, and the same count rule: sz1 + sz2 - 1 chunks (at most
        /// N), and one more for a nonzero carry.
        fn mulChunks(r: *Self, c1: []const u32, c2: []const u32) void {
            const full = c1.len + c2.len - 1;
            if (full > N) {
                // Rare: the result has more than N chunks. Keep the low N
                // chunks, as boost does, and set the flag.
                var tmp: [2 * N]u32 = undefined;
                for (0..full + 1) |k| tmp[k] = 0;
                for (c1, 0..) |a, i| {
                    var carry: u64 = 0;
                    for (c2, 0..) |b, j| {
                        const t = @as(u64, tmp[i + j]) + @as(u64, a) * @as(u64, b) + carry;
                        tmp[i + j] = @truncate(t);
                        carry = t >> 32;
                    }
                    tmp[i + c2.len] = @truncate(carry);
                }
                r.ovf = true;
                r.count = @intCast(N);
                for (0..N) |k| r.chunks[k] = tmp[k];
                return;
            }
            const ch = r.chunks[0..full];
            var top: u32 = 0;
            // The first row sets the chunks, so that no zero fill is needed.
            {
                const a = c1[0];
                var carry: u64 = 0;
                for (c2, 0..) |b, j| {
                    const t = @as(u64, a) * @as(u64, b) + carry;
                    ch[j] = @truncate(t);
                    carry = t >> 32;
                }
                if (c2.len < full) ch[c2.len] = @truncate(carry) else top = @truncate(carry);
            }
            for (c1[1..], 1..) |a, i| {
                var carry: u64 = 0;
                for (c2, 0..) |b, j| {
                    const t = @as(u64, ch[i + j]) + @as(u64, a) * @as(u64, b) + carry;
                    ch[i + j] = @truncate(t);
                    carry = t >> 32;
                }
                if (i + c2.len < full) {
                    ch[i + c2.len] = @truncate(carry);
                } else {
                    top = @truncate(carry);
                }
            }
            r.count = @intCast(full);
            if (top != 0) {
                if (full != N) {
                    r.chunks[full] = top;
                    r.count += 1;
                } else {
                    r.ovf = true;
                }
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Robust floating point: a value and a bound of its relative error in ULPs.

pub const RobustFpt = struct {
    fpv: f64 = 0,
    re: f64 = 0,

    const rounding_error: f64 = 1;

    pub fn init(v: f64) RobustFpt {
        return .{ .fpv = v, .re = 0 };
    }
    pub fn initRe(v: f64, e: f64) RobustFpt {
        return .{ .fpv = v, .re = e };
    }

    pub fn ulp(a: RobustFpt) f64 {
        return a.re;
    }
    pub fn isPos(a: RobustFpt) bool {
        return a.fpv > 0;
    }
    pub fn isNeg(a: RobustFpt) bool {
        return a.fpv < 0;
    }
    pub fn isZero(a: RobustFpt) bool {
        return a.fpv == 0;
    }

    pub fn neg(a: RobustFpt) RobustFpt {
        return .{ .fpv = -a.fpv, .re = a.re };
    }

    pub fn add(a: RobustFpt, b: RobustFpt) RobustFpt {
        const fpv = a.fpv + b.fpv;
        var re: f64 = undefined;
        if ((!(a.fpv < 0) and !(b.fpv < 0)) or (!(a.fpv > 0) and !(b.fpv > 0))) {
            re = @max(a.re, b.re) + rounding_error;
        } else {
            var temp = (a.fpv * a.re - b.fpv * b.re) / fpv;
            if (temp < 0) temp = -temp;
            re = temp + rounding_error;
        }
        return .{ .fpv = fpv, .re = re };
    }

    pub fn sub(a: RobustFpt, b: RobustFpt) RobustFpt {
        const fpv = a.fpv - b.fpv;
        var re: f64 = undefined;
        if ((!(a.fpv < 0) and !(b.fpv > 0)) or (!(a.fpv > 0) and !(b.fpv < 0))) {
            re = @max(a.re, b.re) + rounding_error;
        } else {
            var temp = (a.fpv * a.re + b.fpv * b.re) / fpv;
            if (temp < 0) temp = -temp;
            re = temp + rounding_error;
        }
        return .{ .fpv = fpv, .re = re };
    }

    pub fn mul(a: RobustFpt, b: RobustFpt) RobustFpt {
        return .{ .fpv = a.fpv * b.fpv, .re = a.re + b.re + rounding_error };
    }

    pub fn div(a: RobustFpt, b: RobustFpt) RobustFpt {
        return .{ .fpv = a.fpv / b.fpv, .re = a.re + b.re + rounding_error };
    }

    pub fn sqrt(a: RobustFpt) RobustFpt {
        return .{ .fpv = @sqrt(a.fpv), .re = a.re * 0.5 + rounding_error };
    }
};

/// A difference of two sums of robust values. The parts stay apart, so that
/// the final subtraction is the only place that can lose precision.
pub const RobustDif = struct {
    pos: RobustFpt = .{},
    neg: RobustFpt = .{},

    pub fn init(v: RobustFpt) RobustDif {
        return .{
            .pos = if (v.fpv > 0) v else RobustFpt.init(0),
            .neg = if (v.fpv < 0) v.neg() else RobustFpt.init(0),
        };
    }

    pub fn dif(a: RobustDif) RobustFpt {
        return a.pos.sub(a.neg);
    }

    pub fn negate(a: RobustDif) RobustDif {
        return .{ .pos = a.neg, .neg = a.pos };
    }

    pub fn addV(a: *RobustDif, v: RobustFpt) void {
        if (!(v.fpv < 0)) a.pos = a.pos.add(v) else a.neg = a.neg.sub(v);
    }

    pub fn subV(a: *RobustDif, v: RobustFpt) void {
        if (!(v.fpv < 0)) a.neg = a.neg.add(v) else a.pos = a.pos.sub(v);
    }

    pub fn addD(a: *RobustDif, b: RobustDif) void {
        a.pos = a.pos.add(b.pos);
        a.neg = a.neg.add(b.neg);
    }

    pub fn subD(a: *RobustDif, b: RobustDif) void {
        a.pos = a.pos.add(b.neg);
        a.neg = a.neg.add(b.pos);
    }

    pub fn divV(a: *RobustDif, v: RobustFpt) void {
        if (!(v.fpv < 0)) {
            a.pos = a.pos.div(v);
            a.neg = a.neg.div(v);
        } else {
            a.pos = a.pos.div(v.neg());
            a.neg = a.neg.div(v.neg());
            const t = a.pos;
            a.pos = a.neg;
            a.neg = t;
        }
    }

    /// lhs + rhs for two differences.
    pub fn plus(a: RobustDif, b: RobustDif) RobustDif {
        return .{ .pos = a.pos.add(b.pos), .neg = a.neg.add(b.neg) };
    }

    /// The difference times a value.
    pub fn mulV(a: RobustDif, v: RobustFpt) RobustDif {
        if (!(v.fpv < 0)) {
            return .{ .pos = a.pos.mul(v), .neg = a.neg.mul(v) };
        } else {
            return .{ .pos = a.neg.neg().mul(v), .neg = a.pos.neg().mul(v) };
        }
    }

    /// A value times the difference.
    pub fn vMul(v: RobustFpt, b: RobustDif) RobustDif {
        if (!(v.fpv < 0)) {
            return .{ .pos = v.mul(b.pos), .neg = v.mul(b.neg) };
        } else {
            return .{ .pos = v.neg().mul(b.neg), .neg = v.neg().mul(b.pos) };
        }
    }
};

// ---------------------------------------------------------------------------
// Robust evaluation of sums of square root terms with big integer inputs.
// Each function ORs the overflow flags of its inputs and temporaries into
// `ovf`.

inline fn conv(ovf: *bool, x: anytype) Efpt {
    ovf.* = ovf.* or x.ovf;
    return x.toEfpt();
}

/// A[0] * sqrt(B[0]).
pub fn eval1(comptime Big: type, A: []const Big, B: []const Big, ovf: *bool) Efpt {
    const a = conv(ovf, A[0]);
    const b = conv(ovf, B[0]);
    return a.mul(b.sqrt());
}

/// A[0] * sqrt(B[0]) + A[1] * sqrt(B[1]).
pub fn eval2(comptime Big: type, A: []const Big, B: []const Big, ovf: *bool) Efpt {
    const a = eval1(Big, A, B, ovf);
    const b = eval1(Big, A[1..], B[1..], ovf);
    if ((!a.isNeg() and !b.isNeg()) or (!a.isPos() and !b.isPos())) return a.add(b);
    const num = A[0].mul(A[0]).mul(B[0]).sub(A[1].mul(A[1]).mul(B[1]));
    return conv(ovf, num).div(a.sub(b));
}

/// A[0] * sqrt(B[0]) + A[1] * sqrt(B[1]) + A[2] * sqrt(B[2]).
pub fn eval3(comptime Big: type, A: []const Big, B: []const Big, ovf: *bool) Efpt {
    const a = eval2(Big, A, B, ovf);
    const b = eval1(Big, A[2..], B[2..], ovf);
    if ((!a.isNeg() and !b.isNeg()) or (!a.isPos() and !b.isPos())) return a.add(b);
    var tA: [2]Big = undefined;
    var tB: [2]Big = undefined;
    tA[0] = A[0].mul(A[0]).mul(B[0]).add(A[1].mul(A[1]).mul(B[1])).sub(A[2].mul(A[2]).mul(B[2]));
    tB[0] = Big.from(1);
    tA[1] = A[0].mul(A[1]).muli(2);
    tB[1] = B[0].mul(B[1]);
    return eval2(Big, &tA, &tB, ovf).div(a.sub(b));
}

/// The sum of four terms A[i] * sqrt(B[i]).
pub fn eval4(comptime Big: type, A: []const Big, B: []const Big, ovf: *bool) Efpt {
    const a = eval2(Big, A, B, ovf);
    const b = eval2(Big, A[2..], B[2..], ovf);
    if ((!a.isNeg() and !b.isNeg()) or (!a.isPos() and !b.isPos())) return a.add(b);
    var tA: [3]Big = undefined;
    var tB: [3]Big = undefined;
    tA[0] = A[0].mul(A[0]).mul(B[0]).add(A[1].mul(A[1]).mul(B[1]))
        .sub(A[2].mul(A[2]).mul(B[2])).sub(A[3].mul(A[3]).mul(B[3]));
    tB[0] = Big.from(1);
    tA[1] = A[0].mul(A[1]).muli(2);
    tB[1] = B[0].mul(B[1]);
    tA[2] = A[2].mul(A[3]).muli(-2);
    tB[2] = B[2].mul(B[3]);
    return eval3(Big, &tA, &tB, ovf).div(a.sub(b));
}

test "extended int arithmetic matches i128" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for (0..2000) |_| {
        const a = r.intRangeAtMost(i64, -(1 << 40), 1 << 40);
        const b = r.intRangeAtMost(i64, -(1 << 40), 1 << 40);
        const c = r.intRangeAtMost(i64, -(1 << 20), 1 << 20);
        const want: i128 = @as(i128, a) * b - c;
        const Big = ExtendedInt;
        const got = Big.from(a).mul(Big.from(b)).sub(Big.from(c));
        try std.testing.expectEqual(@as(f64, @floatFromInt(want)), got.d());
        const want2: i128 = @as(i128, a) + b;
        try std.testing.expectEqual(@as(f64, @floatFromInt(want2)), Big.from(a).add(Big.from(b)).d());
        // A small N gives the same value, or sets the flag.
        const Small = ExtendedIntN(2);
        const sm = Small.from(a).mul(Small.from(b)).sub(Small.from(c));
        if (!sm.ovf) try std.testing.expectEqual(got.d(), sm.d());
        if (@abs(a) >= 1 << 33 and @abs(b) >= 1 << 33) try std.testing.expect(Small.from(a).mul(Small.from(b)).mul(Small.from(a)).ovf);
    }
}

test "ulp compare" {
    try std.testing.expectEqual(UlpResult.equal, ulpCmp(1.0, 1.0, 0));
    try std.testing.expectEqual(UlpResult.less, ulpCmp(1.0, 2.0, 64));
    try std.testing.expectEqual(UlpResult.more, ulpCmp(-1.0, -2.0, 64));
    try std.testing.expectEqual(UlpResult.equal, ulpCmp(1.0, std.math.nextAfter(f64, 1.0, 2.0), 1));
}
