//! Tree support: thin branches that hold up the overhangs and grow down to
//! the bed (or to the part), and join on the way.
//!
//! Grid support fills all the space under an overhang. A tree touches the
//! overhang only at points, so it uses less plastic, comes off more
//! easily, and leaves fewer marks on the part. The method:
//!
//! 1. Tips. Each overhang (from support.zig, step 1) gets points on a
//!    regular grid, the same grid on all layers, so that tips line up.
//!    Each overhang island gets at least one point. The top layers under
//!    an overhang are the interface: a dense pad, as in grid support; the
//!    tips start under the pad.
//! 2. Down, one layer at a time. Each branch is a node: a center and a
//!    radius. In one layer, a node moves at most h * tan(branch angle).
//!    It moves away from the part if it is too near (the part moved out by
//!    the XY gap, plus the radius), and toward the nearest other node, if
//!    one is near; two nodes that touch join into one thicker node.
//! 3. The radius grows as the branch goes down (stronger near the bed),
//!    but it gets smaller again where the space is narrow, down to the tip
//!    radius. So a branch can go down a deep, narrow hole. Where it cannot
//!    go on, it rests on the part (it stops the Z gap above it), or, with
//!    bed-only support, it is removed.
//! 4. The area of each layer is the union of the circles of its nodes.
//!    support.zig then adds the interface, and the layer plan prints the
//!    area as it prints grid support.
//!
//! The idea of tree support is common in FDM slicers (Cura "tree support",
//! PrusaSlicer "organic" support; see REFERENCES.md). The method and the
//! code here are new.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const settings_mod = @import("settings.zig");
const slicer = @import("slicer.zig");
const Point = geom.Point;
const Paths = geom.Paths;

const Node = struct {
    x: f64,
    y: f64,
    /// The radius, in µm.
    r: f64,
    alive: bool = true,
};

pub const Params = struct {
    /// The radius of a tip, µm.
    tip: f64,
    /// The largest radius, µm.
    max_r: f64,
    /// The radius grows by this for each µm that a branch goes down.
    growth: f64,
    /// tan of the branch angle from vertical.
    tan_angle: f64,
    /// The distance of the tips, µm.
    spacing: f64,
    /// Empty layers between a branch and the part under it.
    z_gap: usize,
    /// Branches must reach the bed.
    bed_only: bool,
};

/// The tree areas of each layer. `need[i]` is the overhang of layer i,
/// `blocked[i]` the outline of layer i moved out by the XY gap, and `top`
/// the layer index of the tips of the overhang of layer i (i - 1 - gap -
/// interface layers). The result has one Paths for each layer, in `gpa`.
pub fn grow(
    gpa: Allocator,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    need: []const Paths,
    blocked: []const Paths,
    tips_below: usize,
    params: Params,
) Allocator.Error![]Paths {
    const n = outlines.len;
    const out = try gpa.alloc(Paths, n);
    for (out) |*o| o.* = .empty;
    errdefer {
        for (out) |*o| o.deinit(gpa);
        gpa.free(out);
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var nodes: std.ArrayList(Node) = .empty;
    // Each layer adds its circles; the union comes at the end.
    const circles = try arena.alloc(Paths, n);
    for (circles) |*c| c.* = .empty;
    // The branches of each layer, for the bed-only rule: a branch that
    // does not reach the bed is removed, with its circles above. Each node
    // keeps the id of its first tip; the circles keep the id too.
    var j: usize = n;
    while (j > 0) {
        j -= 1;
        // New tips: the overhang of layer src has its tips on layer j.
        const src = j + tips_below;
        if (src < n and !need[src].isEmpty()) try addTips(arena, &nodes, need[src], params);
        if (nodes.items.len == 0) continue;
        const h = geom.fromMm(layers[j].height);
        const step = @as(f64, @floatFromInt(h)) * params.tan_angle;
        // 1. Join nodes that touch.
        joinNodes(nodes.items);
        // 2. Move each node: toward the nearest node, then out of the part.
        for (nodes.items) |*nd| {
            if (!nd.alive) continue;
            if (nearest(nodes.items, nd)) |o| {
                const dx = o.x - nd.x;
                const dy = o.y - nd.y;
                const d = @sqrt(dx * dx + dy * dy);
                // Only toward a node that the branch can reach in a few
                // layers: far branches go straight down.
                if (d > 1e-6 and d < 12 * step + nd.r + o.r) {
                    const m = @min(step, d);
                    nd.x += dx / d * m;
                    nd.y += dy / d * m;
                }
            }
            // The radius grows with the drop, but not over the free space.
            nd.r = @min(params.max_r, nd.r + params.growth * @as(f64, @floatFromInt(h)));
            if (!fit(nd, blocked[j], step, params.tip)) {
                // No room on this layer: the branch rests on the part, or
                // stops (bed only).
                nd.alive = false;
            }
        }
        // A branch over the part rests on it: the z gap above the part.
        for (nodes.items) |*nd| {
            if (!nd.alive) continue;
            var k: usize = 1;
            while (k <= params.z_gap + 1 and k <= j) : (k += 1) {
                if (geom.insideAny(outlines[j - k], .{ .x = @intFromFloat(nd.x), .y = @intFromFloat(nd.y) })) {
                    nd.alive = false;
                    break;
                }
            }
        }
        // 3. The circles of this layer.
        for (nodes.items) |nd| if (nd.alive) try circles[j].append(arena, try circle(arena, nd.x, nd.y, nd.r));
        // Drop the nodes that ended.
        var keep: usize = 0;
        for (nodes.items) |nd| if (nd.alive) {
            nodes.items[keep] = nd;
            keep += 1;
        };
        nodes.items.len = keep;
    }
    // The union of the circles of each layer, minus the part.
    for (0..n) |i| {
        if (circles[i].isEmpty()) continue;
        const u = try clip.unionAll(arena, circles[i], .non_zero);
        const free = try clip.difference(arena, u, blocked[i]);
        out[i] = try free.clone(gpa);
    }
    if (params.bed_only) {
        // Only the areas over support on the layer below.
        for (1..n) |i| {
            if (out[i].isEmpty()) continue;
            const kept = try clip.intersect(gpa, out[i], out[i - 1]);
            out[i].deinit(gpa);
            out[i] = kept;
        }
    }
    return out;
}

/// Adds tips on a grid inside an overhang area, and one tip for each island
/// that the grid misses.
fn addTips(a: Allocator, nodes: *std.ArrayList(Node), area: Paths, params: Params) Allocator.Error!void {
    const b = area.bounds();
    const sp = params.spacing;
    // The grid starts at a multiple of the spacing, so all layers use the
    // same grid. Odd rows move by half a spacing (a triangle grid).
    var row: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(b.min.y)) / sp));
    const row_end: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(b.max.y)) / sp));
    while (row <= row_end) : (row += 1) {
        const y = @as(f64, @floatFromInt(row)) * sp;
        const shift = if (@mod(row, 2) == 0) 0 else sp / 2;
        var col: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(b.min.x)) / sp) - 1);
        const col_end: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(b.max.x)) / sp) + 1);
        while (col <= col_end) : (col += 1) {
            const x = @as(f64, @floatFromInt(col)) * sp + shift;
            if (geom.insideAny(area, .{ .x = @intFromFloat(x), .y = @intFromFloat(y) })) {
                try nodes.append(a, .{ .x = x, .y = y, .r = params.tip });
            }
        }
    }
    // Islands with no tip: a tip at a point inside each one.
    for (0..area.count()) |k| {
        const poly = area.get(k);
        if (geom.area2(poly) <= 0) continue; // a hole
        var has = false;
        for (nodes.items) |nd| {
            if (insidePoly(poly, nd.x, nd.y)) {
                has = true;
                break;
            }
        }
        if (has) continue;
        if (pointInside(poly)) |p| try nodes.append(a, .{ .x = p[0], .y = p[1], .r = params.tip });
    }
}

fn insidePoly(poly: []const Point, x: f64, y: f64) bool {
    var ps: Paths = .empty;
    ps.points.items = @constCast(poly);
    var ends = [_]u32{@intCast(poly.len)};
    ps.ends.items = &ends;
    return geom.insideAny(ps, .{ .x = @intFromFloat(x), .y = @intFromFloat(y) });
}

/// A point inside a polygon: the centroid if it is inside, else the middle
/// of the widest scan line through the centroid height.
fn pointInside(poly: []const Point) ?[2]f64 {
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (poly) |p| {
        cx += @floatFromInt(p.x);
        cy += @floatFromInt(p.y);
    }
    cx /= @floatFromInt(poly.len);
    cy /= @floatFromInt(poly.len);
    if (insidePoly(poly, cx, cy)) return .{ cx, cy };
    // The crossings of the line y = cy.
    var xs: [64]f64 = undefined;
    var nx: usize = 0;
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const ay: f64 = @floatFromInt(a.y);
        const by: f64 = @floatFromInt(b.y);
        if ((ay <= cy) != (by <= cy) and nx < xs.len) {
            const t = (cy - ay) / (by - ay);
            xs[nx] = @as(f64, @floatFromInt(a.x)) + t * @as(f64, @floatFromInt(b.x - a.x));
            nx += 1;
        }
    }
    std.mem.sort(f64, xs[0..nx], {}, std.sort.asc(f64));
    var best: ?[2]f64 = null;
    var best_w: f64 = 0;
    var i: usize = 0;
    while (i + 1 < nx) : (i += 2) {
        if (xs[i + 1] - xs[i] > best_w) {
            best_w = xs[i + 1] - xs[i];
            best = .{ (xs[i] + xs[i + 1]) / 2, cy };
        }
    }
    return best;
}

/// Joins nodes that touch: the new node is at the middle (weighted by the
/// area of each), with the radius of the same area.
fn joinNodes(nodes: []Node) void {
    for (nodes, 0..) |*a, i| {
        if (!a.alive) continue;
        for (nodes[i + 1 ..]) |*b| {
            if (!b.alive) continue;
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const touch = @max(a.r, b.r) * 0.75;
            if (dx * dx + dy * dy > touch * touch) continue;
            const wa = a.r * a.r;
            const wb = b.r * b.r;
            a.x = (a.x * wa + b.x * wb) / (wa + wb);
            a.y = (a.y * wa + b.y * wb) / (wa + wb);
            a.r = @sqrt(wa + wb);
            b.alive = false;
        }
    }
}

fn nearest(nodes: []const Node, nd: *const Node) ?*const Node {
    var best: ?*const Node = null;
    var best_d: f64 = std.math.inf(f64);
    for (nodes) |*o| {
        if (o == nd or !o.alive) continue;
        const dx = o.x - nd.x;
        const dy = o.y - nd.y;
        const d = dx * dx + dy * dy;
        if (d < best_d) {
            best_d = d;
            best = o;
        }
    }
    return best;
}

/// Moves a node out of the part (the blocked area) by at most `step`, and
/// makes its radius smaller where the space is narrow, down to `tip`.
/// Returns false if there is no room.
fn fit(nd: *Node, blocked: Paths, step: f64, tip: f64) bool {
    if (blocked.isEmpty()) return true;
    var moved: f64 = 0;
    var iter: usize = 0;
    while (iter < 4) : (iter += 1) {
        const near = nearestEdge(blocked, nd.x, nd.y);
        const inside = geom.insideAny(blocked, .{ .x = @intFromFloat(nd.x), .y = @intFromFloat(nd.y) });
        const clearance = if (inside) -near.d else near.d;
        if (clearance >= nd.r) return true;
        // Narrow space: a thinner branch fits without a move.
        if (clearance >= tip) {
            nd.r = clearance;
            return true;
        }
        // Move away from the nearest edge point, out of the part.
        if (moved >= step) return false;
        var dx = nd.x - near.x;
        var dy = nd.y - near.y;
        var d = @sqrt(dx * dx + dy * dy);
        if (d < 1e-6) return false;
        if (inside) {
            dx = -dx;
            dy = -dy;
        }
        dx /= d;
        dy /= d;
        const want = @min(step - moved, (if (inside) near.d else 0) + tip - (if (inside) 0 else near.d) + 1);
        d = @max(want, 1);
        nd.x += dx * d;
        nd.y += dy * d;
        moved += d;
    }
    return false;
}

const EdgePoint = struct { x: f64, y: f64, d: f64 };

fn nearestEdge(paths: Paths, x: f64, y: f64) EdgePoint {
    var best: EdgePoint = .{ .x = x, .y = y, .d = std.math.inf(f64) };
    for (0..paths.count()) |k| {
        const poly = paths.get(k);
        for (poly, 0..) |a, i| {
            const b = poly[(i + 1) % poly.len];
            const ax: f64 = @floatFromInt(a.x);
            const ay: f64 = @floatFromInt(a.y);
            const bx: f64 = @floatFromInt(b.x);
            const by: f64 = @floatFromInt(b.y);
            const ex = bx - ax;
            const ey = by - ay;
            const l2 = ex * ex + ey * ey;
            const t = if (l2 > 0) std.math.clamp(((x - ax) * ex + (y - ay) * ey) / l2, 0, 1) else 0;
            const px = ax + t * ex;
            const py = ay + t * ey;
            const d = std.math.hypot(x - px, y - py);
            if (d < best.d) best = .{ .x = px, .y = py, .d = d };
        }
    }
    return best;
}

/// A circle as a counterclockwise polygon with 16 points.
fn circle(a: Allocator, x: f64, y: f64, r: f64) Allocator.Error![]Point {
    const pts = try a.alloc(Point, 16);
    for (pts, 0..) |*p, i| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 16.0;
        p.* = .{ .x = @intFromFloat(@round(x + r * @cos(t))), .y = @intFromFloat(@round(y + r * @sin(t))) };
    }
    return pts;
}
