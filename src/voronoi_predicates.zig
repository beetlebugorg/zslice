//! Geometric predicates of the sweep-line Voronoi builder.
//!
//! The builder in `src/voronoi.zig` asks four questions. This file answers
//! them without errors from rounding:
//!
//! 1. Event order: which site or circle event comes first on the sweep line
//!    (it moves in +x).
//! 2. Beach line order: for a new site, which arc of the beach line is above
//!    it. Each arc is a parabola (point site) or a parabola like curve
//!    (segment site). The predicate compares the distances from the new site
//!    to the arcs along a horizontal line.
//! 3. Circle existence: do three consecutive arcs meet at a point, with the
//!    right orientation, so that the middle arc vanishes.
//! 4. Circle formation: the center of the circle that touches the three
//!    sites, and its rightmost x ("lower_x"), which is the event position.
//!
//! The fast path uses doubles with a bound of the relative error
//! (`RobustFpt`). When the bound is above 64 ULPs, the exact path computes
//! the value again from big integers and square root expressions.
//!
//! This file is a port to Zig of boost::polygon
//! `detail/voronoi_predicates.hpp` (https://github.com/boostorg/polygon,
//! commit ddb9c8adadbbb539fe52cb7f8ee0a446ba5ead04).
//!
//! Copyright Andrii Sydorchuk 2010-2012.
//! Distributed under the Boost Software License, Version 1.0. See
//! licenses/boost-BSL-1.0.txt and REFERENCES.md.

const std = @import("std");
const ct = @import("voronoi_ctypes.zig");

const BigFull = ct.ExtendedInt;
const Rf = ct.RobustFpt;
const Rd = ct.RobustDif;
const Efpt = ct.Efpt;

const ulps: u64 = 64;

pub const Pt = struct {
    x: i32,
    y: i32,

    pub fn eql(a: Pt, b: Pt) bool {
        return a.x == b.x and a.y == b.y;
    }

    /// Point order of boost (`point_comparison_predicate`): x, then y.
    pub fn less(a: Pt, b: Pt) bool {
        if (a.x == b.x) return a.y < b.y;
        return a.x < b.x;
    }
};

pub const inverse_flag: u8 = 0x20;
pub const category_mask: u8 = 0x1F;

/// The source categories, with the values of boost.
pub const cat_single_point: u8 = 0x0;
pub const cat_segment_start_point: u8 = 0x1;
pub const cat_segment_end_point: u8 = 0x2;
pub const cat_initial_segment: u8 = 0x8;
pub const cat_reverse_segment: u8 = 0x9;

/// A site event: a point (p0 == p1) or a segment from p0 to p1.
pub const Site = struct {
    p0: Pt,
    p1: Pt,
    sorted_index: u32 = 0,
    initial_index: u32 = 0,
    flags: u8 = 0,

    pub fn x0(s: *const Site) i64 {
        return s.p0.x;
    }
    pub fn y0(s: *const Site) i64 {
        return s.p0.y;
    }
    pub fn x1(s: *const Site) i64 {
        return s.p1.x;
    }
    pub fn y1(s: *const Site) i64 {
        return s.p1.y;
    }
    pub fn isSegment(s: *const Site) bool {
        return s.p0.x != s.p1.x or s.p0.y != s.p1.y;
    }
    pub fn isInverse(s: *const Site) bool {
        return s.flags & inverse_flag != 0;
    }
    pub fn inverse(s: *Site) void {
        const t = s.p0;
        s.p0 = s.p1;
        s.p1 = t;
        s.flags ^= inverse_flag;
    }
    pub fn category(s: *const Site) u8 {
        return s.flags & category_mask;
    }
    /// Boost `operator==`: the same points.
    pub fn eql(a: *const Site, b: *const Site) bool {
        return a.p0.eql(b.p0) and a.p1.eql(b.p1);
    }
};

pub const Circle = struct {
    x: f64 = 0,
    y: f64 = 0,
    lower_x: f64 = 0,
};

pub fn isVerticalPts(a: Pt, b: Pt) bool {
    return a.x == b.x;
}

pub fn isVertical(s: *const Site) bool {
    return s.p0.x == s.p1.x;
}

inline fn f(v: anytype) f64 {
    return @floatFromInt(v);
}

/// a1 * b2 - b1 * a2 with a relative error of at most one epsilon.
pub fn robustCrossProduct(a1_: i64, b1_: i64, a2_: i64, b2_: i64) f64 {
    const a1: u64 = @abs(a1_);
    const b1: u64 = @abs(b1_);
    const a2: u64 = @abs(a2_);
    const b2: u64 = @abs(b2_);
    const l = a1 *% b2;
    const r = b1 *% a2;
    if ((a1_ < 0) != (b2_ < 0)) {
        if ((a2_ < 0) != (b1_ < 0)) {
            return if (l > r) -f(l - r) else f(r - l);
        } else {
            return -f(l +% r);
        }
    } else {
        if ((a2_ < 0) != (b1_ < 0)) {
            return f(l +% r);
        } else {
            return if (l < r) -f(r - l) else f(l - r);
        }
    }
}

pub const Orientation = enum(i8) { right = -1, collinear = 0, left = 1 };

pub fn otEvalF(v: f64) Orientation {
    if (v == 0) return .collinear;
    return if (v < 0) .right else .left;
}

pub fn otEval4(dx1: i64, dy1: i64, dx2: i64, dy2: i64) Orientation {
    return otEvalF(robustCrossProduct(dx1, dy1, dx2, dy2));
}

pub fn otEval(p1: Pt, p2: Pt, p3: Pt) Orientation {
    const dx1 = @as(i64, p1.x) - p2.x;
    const dx2 = @as(i64, p2.x) - p3.x;
    const dy1 = @as(i64, p1.y) - p2.y;
    const dy2 = @as(i64, p2.y) - p3.y;
    return otEvalF(robustCrossProduct(dx1, dy1, dx2, dy2));
}

// ---------------------------------------------------------------------------
// Event order.

/// Site order for the initial sort (`event_comparison_predicate`).
pub fn siteLess(lhs: *const Site, rhs: *const Site) bool {
    if (lhs.x0() != rhs.x0()) return lhs.x0() < rhs.x0();
    if (!lhs.isSegment()) {
        if (!rhs.isSegment()) return lhs.y0() < rhs.y0();
        if (isVertical(rhs)) return lhs.y0() <= rhs.y0();
        return true;
    } else {
        if (isVertical(rhs)) {
            if (isVertical(lhs)) return lhs.y0() < rhs.y0();
            return false;
        }
        if (isVertical(lhs)) return true;
        if (lhs.y0() != rhs.y0()) return lhs.y0() < rhs.y0();
        return otEval(lhs.p1, lhs.p0, rhs.p1) == .left;
    }
}

pub fn siteLessCircle(lhs: *const Site, rhs: *const Circle) bool {
    return ct.ulpCmp(f(lhs.x0()), rhs.lower_x, ulps) == .less;
}

pub fn circleLess(lhs: *const Circle, rhs: *const Circle) bool {
    if (lhs.lower_x != rhs.lower_x) return lhs.lower_x < rhs.lower_x;
    return lhs.y < rhs.y;
}

// ---------------------------------------------------------------------------
// Distance predicate: does a horizontal line through the new point meet the
// right arc first?

const PredResult = enum { less, undefined, more };

pub fn distancePredicate(left_site: *const Site, right_site: *const Site, new_point: Pt) bool {
    if (!left_site.isSegment()) {
        if (!right_site.isSegment()) {
            return pp(left_site, right_site, new_point);
        } else {
            return ps(left_site, right_site, new_point, false);
        }
    } else {
        if (!right_site.isSegment()) {
            return ps(right_site, left_site, new_point, true);
        } else {
            return ss(left_site, right_site, new_point);
        }
    }
}

fn pp(left_site: *const Site, right_site: *const Site, new_point: Pt) bool {
    const left_point = left_site.p0;
    const right_point = right_site.p0;
    if (left_point.x > right_point.x) {
        if (new_point.y <= left_point.y) return false;
    } else if (left_point.x < right_point.x) {
        if (new_point.y >= right_point.y) return true;
    } else {
        return @as(i64, left_point.y) + @as(i64, right_point.y) < @as(i64, new_point.y) * 2;
    }
    const dist1 = distanceToPointArc(left_site, new_point);
    const dist2 = distanceToPointArc(right_site, new_point);
    return dist1 < dist2;
}

fn ps(left_site: *const Site, right_site: *const Site, new_point: Pt, reverse_order: bool) bool {
    const fast_res = fastPs(left_site, right_site, new_point, reverse_order);
    if (fast_res != .undefined) return fast_res == .less;
    const dist1 = distanceToPointArc(left_site, new_point);
    const dist2 = distanceToSegmentArc(right_site, new_point);
    return reverse_order != (dist1 < dist2);
}

fn ss(left_site: *const Site, right_site: *const Site, new_point: Pt) bool {
    if (left_site.sorted_index == right_site.sorted_index) {
        return otEval(left_site.p0, left_site.p1, new_point) == .left;
    }
    const dist1 = distanceToSegmentArc(left_site, new_point);
    const dist2 = distanceToSegmentArc(right_site, new_point);
    return dist1 < dist2;
}

fn distanceToPointArc(site: *const Site, point: Pt) f64 {
    const dx = f(site.x0()) - f(point.x);
    const dy = f(site.y0()) - f(point.y);
    return (dx * dx + dy * dy) / (2.0 * dx);
}

fn distanceToSegmentArc(site: *const Site, point: Pt) f64 {
    if (isVertical(site)) {
        return (f(site.x0()) - f(point.x)) * 0.5;
    } else {
        const s0 = site.p0;
        const s1 = site.p1;
        const a1 = f(s1.x) - f(s0.x);
        const b1 = f(s1.y) - f(s0.y);
        var k = @sqrt(a1 * a1 + b1 * b1);
        if (!(b1 < 0)) {
            k = 1.0 / (b1 + k);
        } else {
            k = (k - b1) / (a1 * a1);
        }
        return k * robustCrossProduct(
            @as(i64, s1.x) - s0.x,
            @as(i64, s1.y) - s0.y,
            @as(i64, point.x) - s0.x,
            @as(i64, point.y) - s0.y,
        );
    }
}

fn fastPs(left_site: *const Site, right_site: *const Site, new_point: Pt, reverse_order: bool) PredResult {
    const site_point = left_site.p0;
    const segment_start = right_site.p0;
    const segment_end = right_site.p1;
    if (otEval(segment_start, segment_end, new_point) != .right)
        return if (!right_site.isInverse()) .less else .more;

    const dif_x = f(new_point.x) - f(site_point.x);
    const dif_y = f(new_point.y) - f(site_point.y);
    const a = f(segment_end.x) - f(segment_start.x);
    const b = f(segment_end.y) - f(segment_start.y);

    if (isVertical(right_site)) {
        if (new_point.y < site_point.y and !reverse_order) {
            return .more;
        } else if (new_point.y > site_point.y and reverse_order) {
            return .less;
        }
        return .undefined;
    } else {
        const orientation = otEval4(
            @as(i64, segment_end.x) - segment_start.x,
            @as(i64, segment_end.y) - segment_start.y,
            @as(i64, new_point.x) - site_point.x,
            @as(i64, new_point.y) - site_point.y,
        );
        if (orientation == .left) {
            if (!right_site.isInverse()) return if (reverse_order) .less else .undefined;
            return if (reverse_order) .undefined else .more;
        }
    }

    const fast_left_expr = a * (dif_y + dif_x) * (dif_y - dif_x);
    const fast_right_expr = (2.0 * b) * dif_x * dif_y;
    const expr_cmp = ct.ulpCmp(fast_left_expr, fast_right_expr, 4);
    if (expr_cmp != .equal) {
        if ((expr_cmp == .more) != reverse_order) return if (reverse_order) .less else .more;
        return .undefined;
    }
    return .undefined;
}

// ---------------------------------------------------------------------------
// Beach line node order.

/// A beach line key: the bisector of two neighbor arcs.
pub const Key = struct {
    left: Site,
    right: Site,
};

fn comparisonSite(node: *const Key) *const Site {
    if (node.left.sorted_index > node.right.sorted_index) return &node.left;
    return &node.right;
}

fn comparisonPoint(site: *const Site) Pt {
    return if (site.p0.less(site.p1)) site.p0 else site.p1;
}

fn comparisonY(node: *const Key, is_new_node: bool) struct { i64, i32 } {
    if (node.left.sorted_index == node.right.sorted_index) {
        return .{ node.left.y0(), 0 };
    }
    if (node.left.sorted_index > node.right.sorted_index) {
        if (!is_new_node and node.left.isSegment() and isVertical(&node.left)) {
            return .{ node.left.y0(), 1 };
        }
        return .{ node.left.y1(), 1 };
    }
    return .{ node.right.y0(), -1 };
}

/// Node order of the beach line (`node_comparison_predicate`). One of the
/// two nodes is always new, inserted on the current site event.
pub fn nodeLess(node1: *const Key, node2: *const Key) bool {
    const site1 = comparisonSite(node1);
    const site2 = comparisonSite(node2);
    const point1 = comparisonPoint(site1);
    const point2 = comparisonPoint(site2);

    if (point1.x < point2.x) {
        return distancePredicate(&node1.left, &node1.right, point2);
    } else if (point1.x > point2.x) {
        return !distancePredicate(&node2.left, &node2.right, point1);
    } else {
        if (site1.sorted_index == site2.sorted_index) {
            const y1 = comparisonY(node1, true);
            const y2 = comparisonY(node2, true);
            // std::pair operator<.
            if (y1[0] != y2[0]) return y1[0] < y2[0];
            return y1[1] < y2[1];
        } else if (site1.sorted_index < site2.sorted_index) {
            const y1 = comparisonY(node1, false);
            const y2 = comparisonY(node2, true);
            if (y1[0] != y2[0]) return y1[0] < y2[0];
            return if (!site1.isSegment()) (y1[1] < 0) else false;
        } else {
            const y1 = comparisonY(node1, true);
            const y2 = comparisonY(node2, false);
            if (y1[0] != y2[0]) return y1[0] < y2[0];
            return if (!site2.isSegment()) (y2[1] > 0) else true;
        }
    }
}

// ---------------------------------------------------------------------------
// Circle existence.

fn existsPpp(s1: *const Site, s2: *const Site, s3: *const Site) bool {
    return otEval(s1.p0, s2.p0, s3.p0) == .right;
}

fn existsPps(s1: *const Site, s2: *const Site, s3: *const Site, segment_index: i32) bool {
    if (segment_index != 2) {
        const orient1 = otEval(s1.p0, s2.p0, s3.p0);
        const orient2 = otEval(s1.p0, s2.p0, s3.p1);
        if (segment_index == 1 and s1.x0() >= s2.x0()) {
            if (orient1 != .right) return false;
        } else if (segment_index == 3 and s2.x0() >= s1.x0()) {
            if (orient2 != .right) return false;
        } else if (orient1 != .right and orient2 != .right) {
            return false;
        }
    } else {
        return !s3.p0.eql(s1.p0) or !s3.p1.eql(s2.p0);
    }
    return true;
}

fn existsPss(s1: *const Site, s2: *const Site, s3: *const Site, point_index: i32) bool {
    if (s2.sorted_index == s3.sorted_index) return false;
    if (point_index == 2) {
        if (!s2.isInverse() and s3.isInverse()) return false;
        if (s2.isInverse() == s3.isInverse() and otEval(s2.p0, s1.p0, s3.p1) != .right) return false;
    }
    return true;
}

fn existsSss(s1: *const Site, s2: *const Site, s3: *const Site) bool {
    return s1.sorted_index != s2.sorted_index and s2.sorted_index != s3.sorted_index;
}

// ---------------------------------------------------------------------------
// Exact circle formation with big integers.

inline fn tf(ovf: *bool, b: anytype) f64 {
    ovf.* = ovf.* or b.ovf;
    return b.d();
}

fn mpPpp(comptime Big: type, ovf: *bool, s1: *const Site, s2: *const Site, s3: *const Site, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var dif_x: [3]Big = undefined;
    var dif_y: [3]Big = undefined;
    var sum_x: [2]Big = undefined;
    var sum_y: [2]Big = undefined;
    dif_x[0] = Big.from(s1.x0() - s2.x0());
    dif_x[1] = Big.from(s2.x0() - s3.x0());
    dif_x[2] = Big.from(s1.x0() - s3.x0());
    dif_y[0] = Big.from(s1.y0() - s2.y0());
    dif_y[1] = Big.from(s2.y0() - s3.y0());
    dif_y[2] = Big.from(s1.y0() - s3.y0());
    sum_x[0] = Big.from(s1.x0() + s2.x0());
    sum_x[1] = Big.from(s2.x0() + s3.x0());
    sum_y[0] = Big.from(s1.y0() + s2.y0());
    sum_y[1] = Big.from(s2.y0() + s3.y0());
    const inv_denom = 0.5 / tf(ovf, dif_x[0].mul(dif_y[1]).sub(dif_x[1].mul(dif_y[0])));
    const numer1 = dif_x[0].mul(sum_x[0]).add(dif_y[0].mul(sum_y[0]));
    const numer2 = dif_x[1].mul(sum_x[1]).add(dif_y[1].mul(sum_y[1]));

    if (rc_x or rl_x) {
        const c_x = numer1.mul(dif_y[1]).sub(numer2.mul(dif_y[0]));
        c.x = tf(ovf, c_x) * inv_denom;
        if (rl_x) {
            const sqr_r = dif_x[0].mul(dif_x[0]).add(dif_y[0].mul(dif_y[0]))
                .mul(dif_x[1].mul(dif_x[1]).add(dif_y[1].mul(dif_y[1])))
                .mul(dif_x[2].mul(dif_x[2]).add(dif_y[2].mul(dif_y[2])));
            const r = @sqrt(tf(ovf, sqr_r));
            if (!(c.x < 0)) {
                if (!(inv_denom < 0)) {
                    c.lower_x = c.x + r * inv_denom;
                } else {
                    c.lower_x = c.x - r * inv_denom;
                }
            } else {
                const numer = c_x.mul(c_x).sub(sqr_r);
                c.lower_x = tf(ovf, numer) * inv_denom / (tf(ovf, c_x) + r);
            }
        }
    }
    if (rc_y) {
        const c_y = numer2.mul(dif_x[0]).sub(numer1.mul(dif_x[1]));
        c.y = tf(ovf, c_y) * inv_denom;
    }
}

fn mpPps(comptime Big: type, ovf: *bool, s1: *const Site, s2: *const Site, s3: *const Site, segment_index: i32, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var cA: [4]Big = undefined;
    var cB: [4]Big = undefined;
    const line_a = Big.from(s3.y1() - s3.y0());
    const line_b = Big.from(s3.x0() - s3.x1());
    const segm_len = line_a.mul(line_a).add(line_b.mul(line_b));
    const vec_x = Big.from(s2.y0() - s1.y0());
    const vec_y = Big.from(s1.x0() - s2.x0());
    const sum_x = Big.from(s1.x0() + s2.x0());
    const sum_y = Big.from(s1.y0() + s2.y0());
    const teta = line_a.mul(vec_x).add(line_b.mul(vec_y));
    var denom = vec_x.mul(line_b).sub(vec_y.mul(line_a));

    var dif0 = Big.from(s3.y1() - s1.y0());
    var dif1 = Big.from(s1.x0() - s3.x1());
    const A = line_a.mul(dif1).sub(line_b.mul(dif0));
    dif0 = Big.from(s3.y1() - s2.y0());
    dif1 = Big.from(s2.x0() - s3.x1());
    const B = line_a.mul(dif1).sub(line_b.mul(dif0));
    const sum_AB = A.add(B);

    if (denom.isZero()) {
        const numer = teta.mul(teta).sub(sum_AB.mul(sum_AB));
        denom = teta.mul(sum_AB);
        cA[0] = denom.mul(sum_x).muli(2).add(numer.mul(vec_x));
        cB[0] = segm_len;
        cA[1] = denom.mul(sum_AB).muli(2).add(numer.mul(teta));
        cB[1] = Big.from(1);
        cA[2] = denom.mul(sum_y).muli(2).add(numer.mul(vec_y));
        const inv_denom = 1.0 / tf(ovf, denom);
        if (rc_x) c.x = 0.25 * tf(ovf, cA[0]) * inv_denom;
        if (rc_y) c.y = 0.25 * tf(ovf, cA[2]) * inv_denom;
        if (rl_x) {
            c.lower_x = 0.25 * ct.eval2(Big, &cA, &cB, ovf).d() * inv_denom / @sqrt(tf(ovf, segm_len));
        }
        return;
    }

    const det = teta.mul(teta).add(denom.mul(denom)).mul(A).mul(B).muli(4);
    var inv_denom_sqr = 1.0 / tf(ovf, denom);
    inv_denom_sqr *= inv_denom_sqr;

    if (rc_x or rl_x) {
        cA[0] = sum_x.mul(denom).mul(denom).add(teta.mul(sum_AB).mul(vec_x));
        cB[0] = Big.from(1);
        cA[1] = if (segment_index == 2) vec_x.neg() else vec_x;
        cB[1] = det;
        if (rc_x) {
            c.x = 0.5 * ct.eval2(Big, &cA, &cB, ovf).d() * inv_denom_sqr;
        }
    }

    if (rc_y or rl_x) {
        cA[2] = sum_y.mul(denom).mul(denom).add(teta.mul(sum_AB).mul(vec_y));
        cB[2] = Big.from(1);
        cA[3] = if (segment_index == 2) vec_y.neg() else vec_y;
        cB[3] = det;
        if (rc_y) {
            c.y = 0.5 * ct.eval2(Big, cA[2..], cB[2..], ovf).d() * inv_denom_sqr;
        }
    }

    if (rl_x) {
        cB[0] = cB[0].mul(segm_len);
        cB[1] = cB[1].mul(segm_len);
        cA[2] = sum_AB.mul(denom.mul(denom).add(teta.mul(teta)));
        cB[2] = Big.from(1);
        cA[3] = if (segment_index == 2) teta.neg() else teta;
        cB[3] = det;
        c.lower_x = 0.5 * ct.eval4(Big, &cA, &cB, ovf).d() * inv_denom_sqr / @sqrt(tf(ovf, segm_len));
    }
}

fn mpPss(comptime Big: type, ovf: *bool, s1: *const Site, s2: *const Site, s3: *const Site, point_index: i32, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var a: [2]Big = undefined;
    var b: [2]Big = undefined;
    var cc: [2]Big = undefined;
    var cA: [4]Big = undefined;
    var cB: [4]Big = undefined;
    const segm_start1 = s2.p1;
    const segm_end1 = s2.p0;
    const segm_start2 = s3.p0;
    const segm_end2 = s3.p1;
    const st1x: i64 = segm_start1.x;
    const st1y: i64 = segm_start1.y;
    const st2x: i64 = segm_start2.x;
    const st2y: i64 = segm_start2.y;
    const p1x: i64 = s1.x0();
    const p1y: i64 = s1.y0();
    a[0] = Big.from(@as(i64, segm_end1.x) - st1x);
    b[0] = Big.from(@as(i64, segm_end1.y) - st1y);
    a[1] = Big.from(@as(i64, segm_end2.x) - st2x);
    b[1] = Big.from(@as(i64, segm_end2.y) - st2y);
    const orientation = a[1].mul(b[0]).sub(a[0].mul(b[1]));
    if (orientation.isZero()) {
        const denom = 2.0 * tf(ovf, a[0].mul(a[0]).add(b[0].mul(b[0])));
        cc[0] = b[0].muli(st2x - st1x).sub(a[0].muli(st2y - st1y));
        const dx = a[0].muli(p1y - st1y).sub(b[0].muli(p1x - st1x));
        const dy = b[0].muli(p1x - st2x).sub(a[0].muli(p1y - st2y));
        cB[0] = dx.mul(dy);
        cB[1] = Big.from(1);

        if (rc_y) {
            cA[0] = b[0].muli(if (point_index == 2) 2 else -2);
            cA[1] = a[0].mul(a[0]).muli(st1y + st2y)
                .sub(a[0].mul(b[0]).muli(st1x + st2x - p1x * 2))
                .add(b[0].mul(b[0]).muli(p1y * 2));
            const c_y = ct.eval2(Big, &cA, &cB, ovf).d();
            c.y = c_y / denom;
        }

        if (rc_x or rl_x) {
            cA[0] = a[0].muli(if (point_index == 2) 2 else -2);
            cA[1] = b[0].mul(b[0]).muli(st1x + st2x)
                .sub(a[0].mul(b[0]).muli(st1y + st2y - p1y * 2))
                .add(a[0].mul(a[0]).muli(p1x * 2));

            if (rc_x) {
                const c_x = ct.eval2(Big, &cA, &cB, ovf).d();
                c.x = c_x / denom;
            }

            if (rl_x) {
                cA[2] = if (cc[0].isNeg()) cc[0].neg() else cc[0];
                cB[2] = a[0].mul(a[0]).add(b[0].mul(b[0]));
                const lower_x = ct.eval3(Big, &cA, &cB, ovf).d();
                c.lower_x = lower_x / denom;
            }
        }
        return;
    }
    cc[0] = b[0].muli(segm_end1.x).sub(a[0].muli(segm_end1.y));
    cc[1] = a[1].muli(segm_end2.y).sub(b[1].muli(segm_end2.x));
    const ix = a[0].mul(cc[1]).add(a[1].mul(cc[0]));
    const iy = b[0].mul(cc[1]).add(b[1].mul(cc[0]));
    const dx = ix.sub(orientation.muli(p1x));
    const dy = iy.sub(orientation.muli(p1y));
    if (dx.isZero() and dy.isZero()) {
        const denom = tf(ovf, orientation);
        const c_x = tf(ovf, ix) / denom;
        const c_y = tf(ovf, iy) / denom;
        c.* = .{ .x = c_x, .y = c_y, .lower_x = c_x };
        return;
    }

    const sign = Big.from(@as(i64, if (point_index == 2) 1 else -1) * @as(i64, if (orientation.isNeg()) 1 else -1));
    cA[0] = a[1].mul(dx.neg()).add(b[1].mul(dy.neg()));
    cA[1] = a[0].mul(dx.neg()).add(b[0].mul(dy.neg()));
    cA[2] = sign;
    cA[3] = Big.from(0);
    cB[0] = a[0].mul(a[0]).add(b[0].mul(b[0]));
    cB[1] = a[1].mul(a[1]).add(b[1].mul(b[1]));
    cB[2] = a[0].mul(a[1]).add(b[0].mul(b[1]));
    cB[3] = a[0].mul(dy).sub(b[0].mul(dx)).mul(a[1].mul(dy).sub(b[1].mul(dx))).muli(-2);
    const temp = sqrtExprPss4(Big, &cA, &cB, ovf).d();
    const denom = temp * tf(ovf, orientation);

    const dd = dx.mul(dx).add(dy.mul(dy));
    if (rc_y) {
        cA[0] = b[1].mul(dd).sub(iy.mul(dx.mul(a[1]).add(dy.mul(b[1]))));
        cA[1] = b[0].mul(dd).sub(iy.mul(dx.mul(a[0]).add(dy.mul(b[0]))));
        cA[2] = iy.mul(sign);
        const cy = sqrtExprPss4(Big, &cA, &cB, ovf).d();
        c.y = cy / denom;
    }

    if (rc_x or rl_x) {
        cA[0] = a[1].mul(dd).sub(ix.mul(dx.mul(a[1]).add(dy.mul(b[1]))));
        cA[1] = a[0].mul(dd).sub(ix.mul(dx.mul(a[0]).add(dy.mul(b[0]))));
        cA[2] = ix.mul(sign);

        if (rc_x) {
            const cx = sqrtExprPss4(Big, &cA, &cB, ovf).d();
            c.x = cx / denom;
        }

        if (rl_x) {
            cA[3] = orientation.mul(dd).muli(if (temp < 0) -1 else 1);
            const lower_x = sqrtExprPss4(Big, &cA, &cB, ovf).d();
            c.lower_x = lower_x / denom;
        }
    }
}

fn mpSss(comptime Big: type, ovf: *bool, s1: *const Site, s2: *const Site, s3: *const Site, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var a: [3]Big = undefined;
    var b: [3]Big = undefined;
    var cc: [3]Big = undefined;
    var cA: [4]Big = undefined;
    var cB: [4]Big = undefined;
    const ss_ = [3]*const Site{ s1, s2, s3 };
    for (0..3) |i| {
        const s = ss_[i];
        a[i] = Big.from(s.x1() - s.x0());
        b[i] = Big.from(s.y1() - s.y0());
        cc[i] = Big.from(s.x0() * s.y1() - s.y0() * s.x1());
    }
    for (0..3) |i| cB[i] = a[i].mul(a[i]).add(b[i].mul(b[i]));
    for (0..3) |i| {
        const j = (i + 1) % 3;
        const k = (i + 2) % 3;
        cA[i] = a[j].mul(b[k]).sub(a[k].mul(b[j]));
    }
    const denom = ct.eval3(Big, &cA, &cB, ovf).d();

    if (rc_y) {
        for (0..3) |i| {
            const j = (i + 1) % 3;
            const k = (i + 2) % 3;
            cA[i] = b[j].mul(cc[k]).sub(b[k].mul(cc[j]));
        }
        const c_y = ct.eval3(Big, &cA, &cB, ovf).d();
        c.y = c_y / denom;
    }

    if (rc_x or rl_x) {
        cA[3] = Big.from(0);
        for (0..3) |i| {
            const j = (i + 1) % 3;
            const k = (i + 2) % 3;
            cA[i] = a[j].mul(cc[k]).sub(a[k].mul(cc[j]));
            if (rl_x) {
                cA[3] = cA[3].add(cA[i].mul(b[i]));
            }
        }

        if (rc_x) {
            const c_x = ct.eval3(Big, &cA, &cB, ovf).d();
            c.x = c_x / denom;
        }

        if (rl_x) {
            cB[3] = Big.from(1);
            const lower_x = ct.eval4(Big, &cA, &cB, ovf).d();
            c.lower_x = lower_x / denom;
        }
    }
}

/// A[3] + A[0] * sqrt(B[0]) + A[1] * sqrt(B[1]) +
/// A[2] * sqrt(B[3] * (sqrt(B[0] * B[1]) + B[2])).
fn sqrtExprPss4(comptime Big: type, A: []const Big, B: []const Big, ovf: *bool) Efpt {
    var cA: [4]Big = undefined;
    var cB: [4]Big = undefined;
    if (A[3].isZero()) {
        const lh = ct.eval2(Big, A, B, ovf);
        cA[0] = Big.from(1);
        cB[0] = B[0].mul(B[1]);
        cA[1] = B[2];
        cB[1] = Big.from(1);
        const rh = ct.eval1(Big, A[2..], B[3..], ovf).mul(ct.eval2(Big, &cA, &cB, ovf).sqrt());
        if ((!lh.isNeg() and !rh.isNeg()) or (!lh.isPos() and !rh.isPos())) return lh.add(rh);
        cA[0] = A[0].mul(A[0]).mul(B[0]).add(A[1].mul(A[1]).mul(B[1]))
            .sub(A[2].mul(A[2]).mul(B[3]).mul(B[2]));
        cB[0] = Big.from(1);
        cA[1] = A[0].mul(A[1]).muli(2).sub(A[2].mul(A[2]).mul(B[3]));
        cB[1] = B[0].mul(B[1]);
        const numer = ct.eval2(Big, &cA, &cB, ovf);
        return numer.div(lh.sub(rh));
    }
    cA[0] = Big.from(1);
    cB[0] = B[0].mul(B[1]);
    cA[1] = B[2];
    cB[1] = Big.from(1);
    const rh = ct.eval1(Big, A[2..], B[3..], ovf).mul(ct.eval2(Big, &cA, &cB, ovf).sqrt());

    cA[0] = A[0];
    cB[0] = B[0];
    cA[1] = A[1];
    cB[1] = B[1];
    cA[2] = A[3];
    cB[2] = Big.from(1);
    const lh = ct.eval3(Big, &cA, &cB, ovf);

    if ((!lh.isNeg() and !rh.isNeg()) or (!lh.isPos() and !rh.isPos())) return lh.add(rh);
    cA[0] = A[3].mul(A[0]).muli(2);
    cA[1] = A[3].mul(A[1]).muli(2);
    cA[2] = A[0].mul(A[0]).mul(B[0]).add(A[1].mul(A[1]).mul(B[1]))
        .add(A[3].mul(A[3])).sub(A[2].mul(A[2]).mul(B[2]).mul(B[3]));
    cA[3] = A[0].mul(A[1]).muli(2).sub(A[2].mul(A[2]).mul(B[3]));
    cB[3] = B[0].mul(B[1]);
    const numer = sqrtExprPss3(Big, &cA, &cB, ovf);
    return numer.div(lh.sub(rh));
}

/// A[0] * sqrt(B[0]) + A[1] * sqrt(B[1]) + A[2] + A[3] * sqrt(B[0] * B[1]),
/// with B[3] = B[0] * B[1].
fn sqrtExprPss3(comptime Big: type, A: []Big, B: []Big, ovf: *bool) Efpt {
    var cA: [2]Big = undefined;
    var cB: [2]Big = undefined;
    const lh = ct.eval2(Big, A, B, ovf);
    const rh = ct.eval2(Big, A[2..], B[2..], ovf);
    if ((!lh.isNeg() and !rh.isNeg()) or (!lh.isPos() and !rh.isPos())) return lh.add(rh);
    cA[0] = A[0].mul(A[0]).mul(B[0]).add(A[1].mul(A[1]).mul(B[1]))
        .sub(A[2].mul(A[2])).sub(A[3].mul(A[3]).mul(B[0]).mul(B[1]));
    cB[0] = Big.from(1);
    cA[1] = A[0].mul(A[1]).sub(A[2].mul(A[3])).muli(2);
    cB[1] = B[3];
    const numer = ct.eval2(Big, &cA, &cB, ovf);
    return numer.div(lh.sub(rh));
}

/// The exact path. It first uses big integers of 16 chunks. When a value
/// needs more, it computes again with 64 chunks, as boost does.
const BigSmall = ct.ExtendedIntN(16);

fn mpPppD(s1: *const Site, s2: *const Site, s3: *const Site, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var ovf = false;
    var t = c.*;
    mpPpp(BigSmall, &ovf, s1, s2, s3, &t, rc_x, rc_y, rl_x);
    if (!ovf) {
        c.* = t;
        return;
    }
    mpPpp(BigFull, &ovf, s1, s2, s3, c, rc_x, rc_y, rl_x);
}

fn mpPpsD(s1: *const Site, s2: *const Site, s3: *const Site, segment_index: i32, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var ovf = false;
    var t = c.*;
    mpPps(BigSmall, &ovf, s1, s2, s3, segment_index, &t, rc_x, rc_y, rl_x);
    if (!ovf) {
        c.* = t;
        return;
    }
    mpPps(BigFull, &ovf, s1, s2, s3, segment_index, c, rc_x, rc_y, rl_x);
}

fn mpPssD(s1: *const Site, s2: *const Site, s3: *const Site, point_index: i32, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var ovf = false;
    var t = c.*;
    mpPss(BigSmall, &ovf, s1, s2, s3, point_index, &t, rc_x, rc_y, rl_x);
    if (!ovf) {
        c.* = t;
        return;
    }
    mpPss(BigFull, &ovf, s1, s2, s3, point_index, c, rc_x, rc_y, rl_x);
}

fn mpSssD(s1: *const Site, s2: *const Site, s3: *const Site, c: *Circle, rc_x: bool, rc_y: bool, rl_x: bool) void {
    var ovf = false;
    var t = c.*;
    mpSss(BigSmall, &ovf, s1, s2, s3, &t, rc_x, rc_y, rl_x);
    if (!ovf) {
        c.* = t;
        return;
    }
    mpSss(BigFull, &ovf, s1, s2, s3, c, rc_x, rc_y, rl_x);
}

// ---------------------------------------------------------------------------
// Lazy circle formation: doubles with error bounds, and the exact path when
// the bound is too large.

inline fn rf(v: f64) Rf {
    return Rf.init(v);
}

inline fn rfe(v: f64, e: f64) Rf {
    return Rf.initRe(v, e);
}

fn lazyPpp(s1: *const Site, s2: *const Site, s3: *const Site, c: *Circle) void {
    const dif_x1 = f(s1.x0()) - f(s2.x0());
    const dif_x2 = f(s2.x0()) - f(s3.x0());
    const dif_y1 = f(s1.y0()) - f(s2.y0());
    const dif_y2 = f(s2.y0()) - f(s3.y0());
    const orientation = robustCrossProduct(
        s1.x0() - s2.x0(),
        s2.x0() - s3.x0(),
        s1.y0() - s2.y0(),
        s2.y0() - s3.y0(),
    );
    const inv_orientation = rfe(0.5 / orientation, 2.0);
    const sum_x1 = f(s1.x0()) + f(s2.x0());
    const sum_x2 = f(s2.x0()) + f(s3.x0());
    const sum_y1 = f(s1.y0()) + f(s2.y0());
    const sum_y2 = f(s2.y0()) + f(s3.y0());
    const dif_x3 = f(s1.x0()) - f(s3.x0());
    const dif_y3 = f(s1.y0()) - f(s3.y0());
    var c_x: Rd = .{};
    var c_y: Rd = .{};
    c_x.addV(rfe(dif_x1 * sum_x1 * dif_y2, 2.0));
    c_x.addV(rfe(dif_y1 * sum_y1 * dif_y2, 2.0));
    c_x.subV(rfe(dif_x2 * sum_x2 * dif_y1, 2.0));
    c_x.subV(rfe(dif_y2 * sum_y2 * dif_y1, 2.0));
    c_y.addV(rfe(dif_x2 * sum_x2 * dif_x1, 2.0));
    c_y.addV(rfe(dif_y2 * sum_y2 * dif_x1, 2.0));
    c_y.subV(rfe(dif_x1 * sum_x1 * dif_x2, 2.0));
    c_y.subV(rfe(dif_y1 * sum_y1 * dif_x2, 2.0));
    var lower_x = c_x;
    lower_x.subV(rfe(@sqrt((dif_x1 * dif_x1 + dif_y1 * dif_y1) *
        (dif_x2 * dif_x2 + dif_y2 * dif_y2) *
        (dif_x3 * dif_x3 + dif_y3 * dif_y3)), 5.0));
    c.* = .{
        .x = c_x.dif().fpv * inv_orientation.fpv,
        .y = c_y.dif().fpv * inv_orientation.fpv,
        .lower_x = lower_x.dif().fpv * inv_orientation.fpv,
    };
    const rc_x = c_x.dif().ulp() > ulps;
    const rc_y = c_y.dif().ulp() > ulps;
    const rl_x = lower_x.dif().ulp() > ulps;
    if (rc_x or rc_y or rl_x) mpPppD(s1, s2, s3, c, rc_x, rc_y, rl_x);
}

fn lazyPps(s1: *const Site, s2: *const Site, s3: *const Site, segment_index: i32, c: *Circle) void {
    const line_a = f(s3.y1()) - f(s3.y0());
    const line_b = f(s3.x0()) - f(s3.x1());
    const vec_x = f(s2.y0()) - f(s1.y0());
    const vec_y = f(s1.x0()) - f(s2.x0());
    const teta = rfe(robustCrossProduct(
        s3.y1() - s3.y0(),
        s3.x0() - s3.x1(),
        s2.x0() - s1.x0(),
        s2.y0() - s1.y0(),
    ), 1.0);
    const A = rfe(robustCrossProduct(
        s3.y0() - s3.y1(),
        s3.x0() - s3.x1(),
        s3.y1() - s1.y0(),
        s3.x1() - s1.x0(),
    ), 1.0);
    const B = rfe(robustCrossProduct(
        s3.y0() - s3.y1(),
        s3.x0() - s3.x1(),
        s3.y1() - s2.y0(),
        s3.x1() - s2.x0(),
    ), 1.0);
    const denom = rfe(robustCrossProduct(
        s1.y0() - s2.y0(),
        s1.x0() - s2.x0(),
        s3.y1() - s3.y0(),
        s3.x1() - s3.x0(),
    ), 1.0);
    const inv_segm_len = rfe(1.0 / @sqrt(line_a * line_a + line_b * line_b), 3.0);
    var t: Rd = .{};
    if (otEvalF(denom.fpv) == .collinear) {
        t.addV(teta.div(rf(8.0).mul(A)));
        t.subV(A.div(rf(2.0).mul(teta)));
    } else {
        const det = teta.mul(teta).add(denom.mul(denom)).mul(A).mul(B).sqrt();
        if (segment_index == 2) {
            t.subV(det.div(denom.mul(denom)));
        } else {
            t.addV(det.div(denom.mul(denom)));
        }
        t.addV(teta.mul(A.add(B)).div(rf(2.0).mul(denom).mul(denom)));
    }
    var c_x: Rd = .{};
    var c_y: Rd = .{};
    c_x.addV(rf(0.5 * (f(s1.x0()) + f(s2.x0()))));
    c_x.addD(Rd.vMul(rf(vec_x), t));
    c_y.addV(rf(0.5 * (f(s1.y0()) + f(s2.y0()))));
    c_y.addD(Rd.vMul(rf(vec_y), t));

    var r: Rd = .{};
    var lower_x = c_x;
    r.subV(rf(line_a).mul(rf(f(s3.x0()))));
    r.subV(rf(line_b).mul(rf(f(s3.y0()))));
    r.addD(Rd.vMul(rf(line_a), c_x));
    r.addD(Rd.vMul(rf(line_b), c_y));
    if (r.pos.fpv < r.neg.fpv) r = r.negate();
    lower_x.addD(r.mulV(inv_segm_len));
    c.* = .{
        .x = c_x.dif().fpv,
        .y = c_y.dif().fpv,
        .lower_x = lower_x.dif().fpv,
    };
    const rc_x = c_x.dif().ulp() > ulps;
    const rc_y = c_y.dif().ulp() > ulps;
    const rl_x = lower_x.dif().ulp() > ulps;
    if (rc_x or rc_y or rl_x) mpPpsD(s1, s2, s3, segment_index, c, rc_x, rc_y, rl_x);
}

fn lazyPss(s1: *const Site, s2: *const Site, s3: *const Site, point_index: i32, c: *Circle) void {
    const segm_start1 = s2.p1;
    const segm_end1 = s2.p0;
    const segm_start2 = s3.p0;
    const segm_end2 = s3.p1;
    const e1x: i64 = segm_end1.x;
    const e1y: i64 = segm_end1.y;
    const st1x: i64 = segm_start1.x;
    const st1y: i64 = segm_start1.y;
    const e2x: i64 = segm_end2.x;
    const e2y: i64 = segm_end2.y;
    const st2x: i64 = segm_start2.x;
    const st2y: i64 = segm_start2.y;
    const p1x: i64 = s1.x0();
    const p1y: i64 = s1.y0();
    const a1 = f(e1x) - f(st1x);
    const b1 = f(e1y) - f(st1y);
    const a2 = f(e2x) - f(st2x);
    const b2 = f(e2y) - f(st2y);
    var rc_x: bool = undefined;
    var rc_y: bool = undefined;
    var rl_x: bool = undefined;
    const orientation = rfe(robustCrossProduct(e1y - st1y, e1x - st1x, e2y - st2y, e2x - st2x), 1.0);
    if (otEvalF(orientation.fpv) == .collinear) {
        const a = rfe(a1 * a1 + b1 * b1, 2.0);
        const cc = rfe(robustCrossProduct(e1y - st1y, e1x - st1x, st2y - st1y, st2x - st1x), 1.0);
        const det = rfe(robustCrossProduct(e1x - st1x, e1y - st1y, p1x - st1x, p1y - st1y) *
            robustCrossProduct(e1y - st1y, e1x - st1x, p1y - st2y, p1x - st2x), 3.0);
        var t: Rd = .{};
        t.subV(rf(a1).mul(rf((f(st1x) + f(st2x)) * 0.5 - f(p1x))));
        t.subV(rf(b1).mul(rf((f(st1y) + f(st2y)) * 0.5 - f(p1y))));
        if (point_index == 2) {
            t.addV(det.sqrt());
        } else {
            t.subV(det.sqrt());
        }
        t.divV(a);
        var c_x: Rd = .{};
        var c_y: Rd = .{};
        c_x.addV(rf(0.5 * (f(st1x) + f(st2x))));
        c_x.addD(Rd.vMul(rf(a1), t));
        c_y.addV(rf(0.5 * (f(st1y) + f(st2y))));
        c_y.addD(Rd.vMul(rf(b1), t));
        var lower_x = c_x;
        if (cc.isNeg()) {
            lower_x.subV(rf(0.5).mul(cc).div(a.sqrt()));
        } else {
            lower_x.addV(rf(0.5).mul(cc).div(a.sqrt()));
        }
        rc_x = c_x.dif().ulp() > ulps;
        rc_y = c_y.dif().ulp() > ulps;
        rl_x = lower_x.dif().ulp() > ulps;
        c.* = .{ .x = c_x.dif().fpv, .y = c_y.dif().fpv, .lower_x = lower_x.dif().fpv };
    } else {
        const sqr_sum1 = rfe(@sqrt(a1 * a1 + b1 * b1), 2.0);
        const sqr_sum2 = rfe(@sqrt(a2 * a2 + b2 * b2), 2.0);
        var a = rfe(robustCrossProduct(e1x - st1x, e1y - st1y, st2y - e2y, e2x - st2x), 1.0);
        if (!a.isNeg()) {
            a = a.add(sqr_sum1.mul(sqr_sum2));
        } else {
            a = orientation.mul(orientation).div(sqr_sum1.mul(sqr_sum2).sub(a));
        }
        const or1 = rfe(robustCrossProduct(e1y - st1y, e1x - st1x, e1y - p1y, e1x - p1x), 1.0);
        const or2 = rfe(robustCrossProduct(e2x - st2x, e2y - st2y, e2x - p1x, e2y - p1y), 1.0);
        const det = rf(2.0).mul(a).mul(or1).mul(or2);
        const c1 = rfe(robustCrossProduct(e1y - st1y, e1x - st1x, e1y, e1x), 1.0);
        const c2 = rfe(robustCrossProduct(e2x - st2x, e2y - st2y, e2x, e2y), 1.0);
        const inv_orientation = rf(1.0).div(orientation);
        var t: Rd = .{};
        var b: Rd = .{};
        var ix: Rd = .{};
        var iy: Rd = .{};
        ix.addV(rf(a2).mul(c1).mul(inv_orientation));
        ix.addV(rf(a1).mul(c2).mul(inv_orientation));
        iy.addV(rf(b1).mul(c2).mul(inv_orientation));
        iy.addV(rf(b2).mul(c1).mul(inv_orientation));

        b.addD(ix.mulV(rf(a1).mul(sqr_sum2)));
        b.addD(ix.mulV(rf(a2).mul(sqr_sum1)));
        b.addD(iy.mulV(rf(b1).mul(sqr_sum2)));
        b.addD(iy.mulV(rf(b2).mul(sqr_sum1)));
        b.subV(sqr_sum1.mul(rfe(robustCrossProduct(e2x - st2x, e2y - st2y, -p1y, p1x), 1.0)));
        b.subV(sqr_sum2.mul(rfe(robustCrossProduct(e1x - st1x, e1y - st1y, -p1y, p1x), 1.0)));
        t.subD(b);
        if (point_index == 2) {
            t.addV(det.sqrt());
        } else {
            t.subV(det.sqrt());
        }
        t.divV(a.mul(a));
        var c_x = ix;
        var c_y = iy;
        c_x.addD(t.mulV(rf(a1).mul(sqr_sum2)));
        c_x.addD(t.mulV(rf(a2).mul(sqr_sum1)));
        c_y.addD(t.mulV(rf(b1).mul(sqr_sum2)));
        c_y.addD(t.mulV(rf(b2).mul(sqr_sum1)));
        if (t.pos.fpv < t.neg.fpv) t = t.negate();
        var lower_x = c_x;
        if (orientation.isNeg()) {
            lower_x.subD(t.mulV(orientation));
        } else {
            lower_x.addD(t.mulV(orientation));
        }
        rc_x = c_x.dif().ulp() > ulps;
        rc_y = c_y.dif().ulp() > ulps;
        rl_x = lower_x.dif().ulp() > ulps;
        c.* = .{ .x = c_x.dif().fpv, .y = c_y.dif().fpv, .lower_x = lower_x.dif().fpv };
    }
    if (rc_x or rc_y or rl_x) mpPssD(s1, s2, s3, point_index, c, rc_x, rc_y, rl_x);
}

fn lazySss(s1: *const Site, s2: *const Site, s3: *const Site, c: *Circle) void {
    const a1 = rf(f(s1.x1()) - f(s1.x0()));
    const b1 = rf(f(s1.y1()) - f(s1.y0()));
    const c1 = rfe(robustCrossProduct(s1.x0(), s1.y0(), s1.x1(), s1.y1()), 1.0);

    const a2 = rf(f(s2.x1()) - f(s2.x0()));
    const b2 = rf(f(s2.y1()) - f(s2.y0()));
    const c2 = rfe(robustCrossProduct(s2.x0(), s2.y0(), s2.x1(), s2.y1()), 1.0);

    const a3 = rf(f(s3.x1()) - f(s3.x0()));
    const b3 = rf(f(s3.y1()) - f(s3.y0()));
    const c3 = rfe(robustCrossProduct(s3.x0(), s3.y0(), s3.x1(), s3.y1()), 1.0);

    const len1 = a1.mul(a1).add(b1.mul(b1)).sqrt();
    const len2 = a2.mul(a2).add(b2.mul(b2)).sqrt();
    const len3 = a3.mul(a3).add(b3.mul(b3)).sqrt();
    const cross_12 = rfe(robustCrossProduct(s1.x1() - s1.x0(), s1.y1() - s1.y0(), s2.x1() - s2.x0(), s2.y1() - s2.y0()), 1.0);
    const cross_23 = rfe(robustCrossProduct(s2.x1() - s2.x0(), s2.y1() - s2.y0(), s3.x1() - s3.x0(), s3.y1() - s3.y0()), 1.0);
    const cross_31 = rfe(robustCrossProduct(s3.x1() - s3.x0(), s3.y1() - s3.y0(), s1.x1() - s1.x0(), s1.y1() - s1.y0()), 1.0);

    var denom: Rd = .{};
    denom.addV(cross_12.mul(len3));
    denom.addV(cross_23.mul(len1));
    denom.addV(cross_31.mul(len2));

    var r: Rd = .{};
    r.subV(cross_12.mul(c3));
    r.subV(cross_23.mul(c1));
    r.subV(cross_31.mul(c2));

    var c_x: Rd = .{};
    c_x.addV(a1.mul(c2).mul(len3));
    c_x.subV(a2.mul(c1).mul(len3));
    c_x.addV(a2.mul(c3).mul(len1));
    c_x.subV(a3.mul(c2).mul(len1));
    c_x.addV(a3.mul(c1).mul(len2));
    c_x.subV(a1.mul(c3).mul(len2));

    var c_y: Rd = .{};
    c_y.addV(b1.mul(c2).mul(len3));
    c_y.subV(b2.mul(c1).mul(len3));
    c_y.addV(b2.mul(c3).mul(len1));
    c_y.subV(b3.mul(c2).mul(len1));
    c_y.addV(b3.mul(c1).mul(len2));
    c_y.subV(b1.mul(c3).mul(len2));

    const lower_x = c_x.plus(r);

    const denom_dif = denom.dif();
    const c_x_dif = c_x.dif().div(denom_dif);
    const c_y_dif = c_y.dif().div(denom_dif);
    const lower_x_dif = lower_x.dif().div(denom_dif);

    const rc_x = c_x_dif.ulp() > ulps;
    const rc_y = c_y_dif.ulp() > ulps;
    const rl_x = lower_x_dif.ulp() > ulps;
    c.* = .{ .x = c_x_dif.fpv, .y = c_y_dif.fpv, .lower_x = lower_x_dif.fpv };
    if (rc_x or rc_y or rl_x) mpSssD(s1, s2, s3, c, rc_x, rc_y, rl_x);
}

// ---------------------------------------------------------------------------
// Circle formation predicate.

fn liesOutsideVerticalSegment(c: *const Circle, s: *const Site) bool {
    if (!s.isSegment() or !isVertical(s)) return false;
    const y0 = f(if (s.isInverse()) s.y1() else s.y0());
    const y1 = f(if (s.isInverse()) s.y0() else s.y1());
    return ct.ulpCmp(c.y, y0, ulps) == .less or ct.ulpCmp(c.y, y1, ulps) == .more;
}

/// Makes the circle event of three consecutive sites. Returns false when
/// the three sites make no circle event.
pub fn circleFormation(s1: *const Site, s2: *const Site, s3: *const Site, c: *Circle) bool {
    if (!s1.isSegment()) {
        if (!s2.isSegment()) {
            if (!s3.isSegment()) {
                if (!existsPpp(s1, s2, s3)) return false;
                lazyPpp(s1, s2, s3, c);
            } else {
                if (!existsPps(s1, s2, s3, 3)) return false;
                lazyPps(s1, s2, s3, 3, c);
            }
        } else {
            if (!s3.isSegment()) {
                if (!existsPps(s1, s3, s2, 2)) return false;
                lazyPps(s1, s3, s2, 2, c);
            } else {
                if (!existsPss(s1, s2, s3, 1)) return false;
                lazyPss(s1, s2, s3, 1, c);
            }
        }
    } else {
        if (!s2.isSegment()) {
            if (!s3.isSegment()) {
                if (!existsPps(s2, s3, s1, 1)) return false;
                lazyPps(s2, s3, s1, 1, c);
            } else {
                if (!existsPss(s2, s1, s3, 2)) return false;
                lazyPss(s2, s1, s3, 2, c);
            }
        } else {
            if (!s3.isSegment()) {
                if (!existsPss(s3, s1, s2, 3)) return false;
                lazyPss(s3, s1, s2, 3, c);
            } else {
                if (!existsSss(s1, s2, s3)) return false;
                lazySss(s1, s2, s3, c);
            }
        }
    }
    if (liesOutsideVerticalSegment(c, s1) or
        liesOutsideVerticalSegment(c, s2) or
        liesOutsideVerticalSegment(c, s3)) return false;
    return true;
}
