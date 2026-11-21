//! Skeletal trapezoidation: the center lines of a shape, and the variable
//! width beads along them.
//!
//! Picture a cone on each point of the outline, with its tip down, so
//! that the height of the surface over a point is its distance to the
//! outline. The ridges of that surface are the medial axis (the center
//! lines). The method works on a graph of the ridges:
//!
//! 1. The segment Voronoi diagram of the outline (see `voronoi.zig`) gives
//!    the ridges. Each Voronoi cell of an outline segment, or of an
//!    outline vertex, becomes a "quad": a chain of half-edges from the
//!    outline, up along the ridge, and back down to the outline. Each node
//!    on the ridge gets a "rib" to its closest point on the outline. A
//!    curved Voronoi edge (between a point and a segment) is cut into short
//!    straight pieces. Each node keeps its distance to the outline (R).
//! 2. An edge is "central" if R grows slowly along it (the two sides of
//!    the part are close to parallel). Only central edges get a bead count.
//! 3. The bead count of each central node comes from the beading strategy
//!    for the thickness 2R. Where the count changes along an edge, the
//!    method puts a transition: a ramp of a given length over which one
//!    bead splits into two, or two merge. Transitions too close together
//!    cancel out. Each transition end gets a new node and a new rib.
//! 4. Each node gets a beading: the widths and the positions of its beads.
//!    The beadings spread from the central nodes up and down the graph.
//! 5. On each rib, each bead gets a junction at its distance from the
//!    outline. The junctions of each quad connect into line pieces.
//!
//! The method is from the paper "A framework for adaptive width control of
//! dense contour-parallel toolpaths in fused deposition modeling" by
//! Kuipers et al. (Computer-Aided Design 128, 2020). This file is a port
//! to Zig of CuraEngine (https://github.com/Ultimaker/CuraEngine, commit
//! 5eff812d2124b2eb93f832e92d33ccdba721135b):
//! `src/arachne/SkeletalTrapezoidation.cpp`,
//! `src/arachne/SkeletalTrapezoidationGraph.cpp`,
//! `src/arachne/STHalfEdge.cpp`, `src/arachne/STHalfEdgeNode.cpp`, the
//! headers in `include/arachne/` (`SkeletalTrapezoidationEdge.h`,
//! `SkeletalTrapezoidationJoint.h`), and the parts of
//! `src/utils/voronoi_utils.cpp` that it uses. The order of the method and
//! its integer arithmetic follow the C++ code. The differences: the
//! graph has arrays of pointers in place of `std::list`, and removed edges
//! and nodes get a flag; the lists of transitions mark removed items; the
//! order of the quads in `connectJunctions` is the order of the edges; the
//! Voronoi vertices round to the nearest micrometer (the integer vertex
//! type of CuraEngine truncates them).
//!
//! Copyright (c) 2026 UltiMaker. CuraEngine is released under the terms of
//! the AGPLv3 or higher. This port is part of zslice (AGPL-3.0-or-later).
//! See docs/references/.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("../geom.zig");
const voronoi = @import("../voronoi.zig");
const beading_mod = @import("beading.zig");
const extrusion = @import("extrusion.zig");
const Point = geom.Point;
const Strategy = beading_mod.Strategy;
const Beading = beading_mod.Beading;
const Junction = extrusion.Junction;
const Line = extrusion.Line;
const Lines = extrusion.Lines;
const vSize = extrusion.vSize;
const vSize2 = extrusion.vSize2;

const EdgeType = enum { normal, extra_vd, transition_end };
const Central = enum { unknown, no, yes };

const TransitionMiddle = struct {
    /// The position along the edge, from `from`.
    pos: i64,
    lower_bead_count: i64,
    /// The feature radius at the transition.
    feature_radius: i64,
    /// Removed (CuraEngine erases it from a `std::list`).
    dead: bool = false,
};

const TransitionEnd = struct {
    /// The position along the edge, from `from`. The edge goes from low R
    /// to high R.
    pos: i64,
    lower_bead_count: i64,
    /// The end of the transition with the lower bead count.
    is_lower_end: bool,
};

const BeadingPropagation = struct {
    beading: Beading,
    dist_to_bottom_source: i64 = 0,
    dist_from_top_source: i64 = 0,
    is_upward_propagated_only: bool = false,
};

const Transitions = std.ArrayList(TransitionMiddle);
const TransitionEnds = std.ArrayList(TransitionEnd);
const LineJunctions = std.ArrayList(Junction);

pub const Node = struct {
    p: Point,
    incident_edge: ?*Edge = null,
    distance_to_boundary: i64 = -1,
    bead_count: i64 = -1,
    /// The part of the inner bead width to leave free, because the node is
    /// in the middle of a transition.
    transition_ratio: f64 = 0,
    beading: ?*BeadingPropagation = null,
    dead: bool = false,

    fn hasBeading(n: *const Node) bool {
        return n.beading != null;
    }

    /// True if more than two central edges meet here.
    fn isMultiIntersection(n: *const Node) bool {
        var odd_path_count: usize = 0;
        const first = n.incident_edge orelse return false;
        var outgoing: *Edge = first;
        var steps: usize = 0;
        while (true) {
            if (outgoing.isCentral()) odd_path_count += 1;
            // A node on the outside.
            const tw = outgoing.twin orelse return false;
            outgoing = tw.next orelse return false;
            if (outgoing == first) break;
            // A broken fan of edges (a degenerate shape): stop.
            steps += 1;
            if (steps > 10_000) return false;
        }
        return odd_path_count > 2;
    }

    fn isCentral(n: *const Node) bool {
        const first = n.incident_edge orelse return false;
        var edge: *Edge = first;
        while (true) {
            if (edge.isCentral()) return true;
            const tw = edge.twin orelse return false;
            edge = tw.next orelse return false;
            if (edge == first) break;
        }
        return false;
    }

    fn isLocalMaximum(n: *const Node, strict: bool) bool {
        if (n.distance_to_boundary == 0) return false;
        const first = n.incident_edge orelse return false;
        var edge: *Edge = first;
        while (true) {
            if (edge.canGoUp(strict)) return false;
            const tw = edge.twin orelse return false;
            // A node on the boundary.
            edge = tw.next orelse return false;
            if (edge == first) break;
        }
        return true;
    }
};

pub const Edge = struct {
    twin: ?*Edge = null,
    next: ?*Edge = null,
    prev: ?*Edge = null,
    from: *Node = undefined,
    to: *Node = undefined,
    type: EdgeType = .normal,
    central: Central = .unknown,
    transitions: ?*Transitions = null,
    transition_ends: ?*TransitionEnds = null,
    junctions: ?*LineJunctions = null,
    dead: bool = false,
    /// The quad of this edge was walked in `connectJunctions`.
    quad_done: bool = false,
    /// An odd segment on this edge was made (`connectJunctions`).
    passed_odd: bool = false,

    fn isCentral(e: *const Edge) bool {
        return e.central == .yes;
    }

    fn setIsCentral(e: *Edge, b: bool) void {
        e.central = if (b) .yes else .no;
    }

    fn centralIsSet(e: *const Edge) bool {
        return e.central != .unknown;
    }

    fn hasTransitions(e: *const Edge, ignore_empty: bool) bool {
        const t = e.transitions orelse return false;
        return ignore_empty or liveCount(t) > 0;
    }

    fn hasTransitionEnds(e: *const Edge, ignore_empty: bool) bool {
        const t = e.transition_ends orelse return false;
        return ignore_empty or t.items.len > 0;
    }

    fn hasExtrusionJunctions(e: *const Edge, ignore_empty: bool) bool {
        const j = e.junctions orelse return false;
        return ignore_empty or j.items.len > 0;
    }

    fn canGoUp(e: *const Edge, strict: bool) bool {
        if (e.to.distance_to_boundary > e.from.distance_to_boundary) return true;
        if (e.to.distance_to_boundary < e.from.distance_to_boundary or strict) return false;
        var o = e.next;
        while (o) |outgoing| {
            if (outgoing == e.twin) break;
            if (outgoing.canGoUp(false)) return true;
            const tw = outgoing.twin orelse return false;
            // A point on the boundary: this should not occur.
            o = tw.next orelse return true;
        }
        return false;
    }

    fn isUpward(e: *const Edge) bool {
        if (e.to.distance_to_boundary > e.from.distance_to_boundary) return true;
        if (e.to.distance_to_boundary < e.from.distance_to_boundary) return false;
        const forward_up_dist = e.distToGoUp();
        const backward_up_dist = e.twin.?.distToGoUp();
        if (forward_up_dist != null and backward_up_dist != null) return forward_up_dist.? < backward_up_dist.?;
        if (forward_up_dist != null) return true;
        if (backward_up_dist != null) return false;
        // An arbitrary order, which gives the opposite for the twin.
        return e.to.p.lessThan(e.from.p);
    }

    fn distToGoUp(e: *const Edge) ?i64 {
        if (e.to.distance_to_boundary > e.from.distance_to_boundary) return 0;
        if (e.to.distance_to_boundary < e.from.distance_to_boundary) return null;
        var ret: ?i64 = null;
        var o = e.next;
        while (o) |outgoing| {
            if (outgoing == e.twin) break;
            if (outgoing.distToGoUp()) |d| {
                ret = if (ret) |r| @min(r, d) else d;
            }
            const tw = outgoing.twin orelse return null;
            // A point on the boundary: this should not occur.
            o = tw.next orelse return 0;
        }
        if (ret) |r| return r + vSize(e.to.p.sub(e.from.p));
        return null;
    }

    fn getNextUnconnected(e: *Edge) ?*Edge {
        var result: *Edge = e;
        while (result.next) |n| {
            result = n;
            if (result == e) return null;
        }
        return result.twin;
    }
};

fn liveCount(t: *const Transitions) usize {
    var n: usize = 0;
    for (t.items) |m| {
        if (!m.dead) n += 1;
    }
    return n;
}

fn firstLive(t: *Transitions) ?*TransitionMiddle {
    for (t.items) |*m| {
        if (!m.dead) return m;
    }
    return null;
}

fn lastLive(t: *Transitions) ?*TransitionMiddle {
    var i = t.items.len;
    while (i > 0) {
        i -= 1;
        if (!t.items[i].dead) return &t.items[i];
    }
    return null;
}

/// The parameters of the method (lengths in micrometers).
pub const Params = struct {
    transitioning_angle: f64,
    discretization_step_size: i64,
    transition_filter_dist: i64,
    allowed_filter_deviation: i64,
    beading_propagation_transition_dist: i64,
};

/// Filter central areas smaller than this.
const central_filter_dist: i64 = 20;
/// The arithmetic error: a transition this close to a node needs no new
/// edge.
const snap_dist: i64 = 20;
/// The limit of the search for a nearby beading.
const bead_search_max: usize = 1000;

/// A polygon edge, from `from` to `to`, as CuraEngine
/// `PolygonsSegmentIndex`.
const Segment = struct { from: Point, to: Point };

pub const SkeletalTrapezoidation = struct {
    a: Allocator,
    strategy: *const Strategy,
    params: Params,
    nodes: std.ArrayList(*Node) = .empty,
    edges: std.ArrayList(*Edge) = .empty,
    /// The toolpaths, one list for each wall.
    out: *std.ArrayList(Lines) = undefined,

    // The Voronoi input and the maps from it to the graph.
    segments: []Segment = &.{},
    vd_edge_to_he_edge: []?*Edge = &.{},
    vd_node_to_he_node: []?*Node = &.{},

    /// Builds the graph of the polygons. All memory is in `a` (an arena).
    pub fn init(a: Allocator, polys: geom.Paths, strategy: *const Strategy, params: Params) !SkeletalTrapezoidation {
        var st: SkeletalTrapezoidation = .{ .a = a, .strategy = strategy, .params = params };
        try st.constructFromPolygons(polys);
        // A degenerate input (a sliver, points on a line) can give a graph
        // with a missing link; the steps after this one follow the links,
        // so such a graph is an error here, not a crash later.
        if (!st.linked()) return error.Degenerate;
        return st;
    }

    /// True if each live edge has a live twin that has it as its twin, and
    /// its next edge (if any) has it as its previous edge.
    fn linked(st: *const SkeletalTrapezoidation) bool {
        for (st.edges.items) |e| {
            if (e.dead) continue;
            const tw = e.twin orelse return false;
            if (tw.dead or tw.twin != e) return false;
            if (e.next) |n| if (!n.dead and n.prev != e) return false;
            if (e.prev) |pv| if (!pv.dead and pv.next != e) return false;
        }
        // The edges around each node: a walk from one edge to the next
        // (twin, then next) comes back to the first one, or ends at the
        // boundary. A walk that does neither would never end.
        for (st.nodes.items) |n| {
            const first = n.incident_edge orelse continue;
            if (first.dead) continue;
            var e = first;
            var steps: usize = 0;
            while (true) {
                const tw = e.twin orelse break;
                e = tw.next orelse break;
                if (e == first) break;
                steps += 1;
                if (steps > max_fan) return false;
            }
        }
        return true;
    }

    /// The most edges around one node (a check of the graph).
    const max_fan = 10_000;

    fn newNode(st: *SkeletalTrapezoidation, p: Point) Allocator.Error!*Node {
        const n = try st.a.create(Node);
        n.* = .{ .p = p };
        try st.nodes.append(st.a, n);
        return n;
    }

    fn newEdge(st: *SkeletalTrapezoidation, t: EdgeType) Allocator.Error!*Edge {
        const e = try st.a.create(Edge);
        e.* = .{ .type = t };
        try st.edges.append(st.a, e);
        return e;
    }

    // ---------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------

    fn vdPoint(d: *const voronoi.Diagram, v: u32) Point {
        const vx = d.vertices[v];
        return .{ .x = @intFromFloat(@round(vx.x)), .y = @intFromFloat(@round(vx.y)) };
    }

    fn makeNode(st: *SkeletalTrapezoidation, vd_node: u32, p: Point) Allocator.Error!*Node {
        if (st.vd_node_to_he_node[vd_node]) |n| return n;
        const n = try st.newNode(p);
        st.vd_node_to_he_node[vd_node] = n;
        return n;
    }

    fn sourcePoint(st: *const SkeletalTrapezoidation, cell: voronoi.Cell) Point {
        const s = st.segments[cell.source_index];
        return switch (cell.source_category) {
            .segment_start_point => s.to,
            .segment_end_point => s.from,
            else => unreachable,
        };
    }

    fn sourceSegment(st: *const SkeletalTrapezoidation, cell: voronoi.Cell) Segment {
        return st.segments[cell.source_index];
    }

    fn constructFromPolygons(st: *SkeletalTrapezoidation, polys: geom.Paths) !void {
        const a = st.a;
        var segs: std.ArrayList(Segment) = .empty;
        var vsegs: std.ArrayList([2]Point) = .empty;
        for (0..polys.count()) |pi| {
            const poly = polys.get(pi);
            for (poly, 0..) |q, k| {
                const r = poly[(k + 1) % poly.len];
                try segs.append(a, .{ .from = q, .to = r });
                // The low point of a boost segment is the end of the edge
                // (see CuraEngine `BoostInterface.hpp`).
                try vsegs.append(a, .{ r, q });
            }
        }
        st.segments = segs.items;
        var vd = try voronoi.build(a, &.{}, vsegs.items);
        defer vd.deinit(a);
        st.vd_edge_to_he_edge = try a.alloc(?*Edge, vd.edges.len);
        @memset(st.vd_edge_to_he_edge, null);
        st.vd_node_to_he_node = try a.alloc(?*Node, vd.vertices.len);
        @memset(st.vd_node_to_he_node, null);

        for (vd.cells) |cell| {
            const incident = cell.incident_edge orelse continue;
            _ = incident;
            var start_source_point: Point = undefined;
            var end_source_point: Point = undefined;
            var starting_vd_edge: ?u32 = null;
            var ending_vd_edge: ?u32 = null;
            if (cell.containsPoint()) {
                if (!st.computePointCellRange(&vd, cell, &start_source_point, &end_source_point, &starting_vd_edge, &ending_vd_edge, polys)) continue;
            } else {
                st.computeSegmentCellRange(&vd, cell, &start_source_point, &end_source_point, &starting_vd_edge, &ending_vd_edge);
            }
            // Each cell starts and ends in a polygon vertex.
            const start_e = starting_vd_edge orelse continue;
            const end_e = ending_vd_edge orelse continue;
            // Copy the edges from the start to the end to the graph.
            var prev_edge: ?*Edge = null;
            try st.transferEdge(start_source_point, vdPoint(&vd, (vd.vertex1(start_e) orelse return error.Degenerate)), &vd, start_e, &prev_edge, start_source_point, end_source_point);
            const starting_node = (st.vd_node_to_he_node[(vd.edges[start_e].vertex0 orelse return error.Degenerate)] orelse return error.Degenerate);
            starting_node.distance_to_boundary = 0;
            try st.makeRib(&prev_edge, start_source_point, end_source_point);
            var vd_edge = vd.edges[start_e].next;
            while (vd_edge != end_e) : (vd_edge = vd.edges[vd_edge].next) {
                const v1 = vdPoint(&vd, (vd.edges[vd_edge].vertex0 orelse return error.Degenerate));
                const v2 = vdPoint(&vd, (vd.vertex1(vd_edge) orelse return error.Degenerate));
                try st.transferEdge(v1, v2, &vd, vd_edge, &prev_edge, start_source_point, end_source_point);
                try st.makeRib(&prev_edge, start_source_point, end_source_point);
            }
            try st.transferEdge(vdPoint(&vd, (vd.edges[end_e].vertex0 orelse return error.Degenerate)), end_source_point, &vd, end_e, &prev_edge, start_source_point, end_source_point);
            (prev_edge orelse return error.Degenerate).to.distance_to_boundary = 0;
        }
        try st.separatePointyQuadEndNodes();
        st.collapseSmallEdges(5);
        // Set the incident edge to the first edge of a quad, so that a walk
        // from the incident edge reaches all edges without going back.
        for (st.edges.items) |e| {
            if (e.dead) continue;
            if (e.prev == null) e.from.incident_edge = e;
        }
    }

    fn transferEdge(st: *SkeletalTrapezoidation, from: Point, to: Point, vd: *const voronoi.Diagram, vd_edge: u32, prev_edge: *?*Edge, start_source_point: Point, end_source_point: Point) !void {
        if (st.vd_edge_to_he_edge[voronoi.Diagram.twin(vd_edge)]) |source_twin| {
            // The twin edges are made already.
            const end_node = st.vd_node_to_he_node[(vd.vertex1(vd_edge) orelse return error.Degenerate)] orelse return;
            var twin: *Edge = source_twin;
            while (true) {
                const edge = try st.newEdge(.normal);
                edge.from = twin.to;
                edge.to = twin.from;
                edge.twin = twin;
                twin.twin = edge;
                edge.from.incident_edge = edge;
                if (prev_edge.*) |pe| {
                    edge.prev = pe;
                    pe.next = edge;
                }
                prev_edge.* = edge;
                if (edge.to == end_node) return;
                // The discretized segment behaves oddly.
                const tp = twin.prev orelse return;
                const tpt = tp.twin orelse return;
                const tptp = tpt.prev orelse return;
                try st.makeRib(prev_edge, start_source_point, end_source_point);
                twin = tptp;
            }
        }
        const discretized = try st.discretize(vd, vd_edge);
        if (discretized.len < 2) return;
        var v0: *Node = if (prev_edge.*) |pe| pe.to else try st.makeNode((vd.edges[vd_edge].vertex0 orelse return error.Degenerate), from);
        for (1..discretized.len) |p1_idx| {
            const p1 = discretized[p1_idx];
            const v1: *Node = if (p1_idx < discretized.len - 1) try st.newNode(p1) else try st.makeNode((vd.vertex1(vd_edge) orelse return error.Degenerate), to);
            const edge = try st.newEdge(.normal);
            edge.from = v0;
            edge.to = v1;
            edge.from.incident_edge = edge;
            if (prev_edge.*) |pe| {
                edge.prev = pe;
                pe.next = edge;
            }
            prev_edge.* = edge;
            v0 = v1;
            // The rib of the last segment comes outside this function.
            if (p1_idx < discretized.len - 1) try st.makeRib(prev_edge, start_source_point, end_source_point);
        }
        st.vd_edge_to_he_edge[vd_edge] = prev_edge.* orelse return error.Degenerate;
    }

    /// Points along a Voronoi edge. A curved edge (between a point and a
    /// segment) is cut into short straight pieces. A straight edge between
    /// two points is cut too: the width along it changes as a parabola.
    fn discretize(st: *SkeletalTrapezoidation, vd: *const voronoi.Diagram, vd_edge: u32) ![]Point {
        const a = st.a;
        const e = vd.edges[vd_edge];
        const left_cell = vd.cells[e.cell];
        const right_cell = vd.cells[vd.edges[voronoi.Diagram.twin(vd_edge)].cell];
        const start = vdPoint(vd, (e.vertex0 orelse return error.Degenerate));
        const end = vdPoint(vd, (vd.vertex1(vd_edge) orelse return error.Degenerate));
        const point_left = left_cell.containsPoint();
        const point_right = right_cell.containsPoint();
        // A source vertex connected to its source segment.
        if ((!point_left and !point_right) or !e.is_primary) {
            return try a.dupe(Point, &.{ start, end });
        }
        if (point_left != point_right) {
            // A parabola between a point and a segment.
            const p = st.sourcePoint(if (point_left) left_cell else right_cell);
            const s = st.sourceSegment(if (point_left) right_cell else left_cell);
            return discretizeParabola(a, p, s, start, end, st.params.discretization_step_size, st.params.transitioning_angle);
        }
        // A straight edge between two points. The part gets narrower toward
        // the middle of the two points, so the beadings can change along it.
        const left_point = st.sourcePoint(left_cell);
        const right_point = st.sourcePoint(right_cell);
        const d = vSize(right_point.sub(left_point));
        const middle: Point = .{ .x = @divTrunc(left_point.x + right_point.x, 2), .y = @divTrunc(left_point.y + right_point.y, 2) };
        const x_axis_dir = turn90CCW(right_point.sub(left_point));
        const x_axis_length = vSize(x_axis_dir);
        const projX = struct {
            fn f(from: Point, mid: Point, dir: Point, len: i64) i64 {
                const vec = from.sub(mid);
                return @divTrunc(vec.x * dir.x + vec.y * dir.y, len);
            }
        }.f;
        const start_x = projX(start, middle, x_axis_dir, x_axis_length);
        const end_x = projX(end, middle, x_axis_dir, x_axis_length);
        // The part of the edge bound to the markings at its ends.
        const bound = 0.5 / @tan((std.math.pi - st.params.transitioning_angle) * 0.5);
        var marking_start_x: i64 = beading_mod.trunc(-@as(f64, @floatFromInt(d)) * bound);
        var marking_end_x: i64 = beading_mod.trunc(@as(f64, @floatFromInt(d)) * bound);
        var marking_start = middle.add(divP(mulP(x_axis_dir, marking_start_x), x_axis_length));
        var marking_end = middle.add(divP(mulP(x_axis_dir, marking_end_x), x_axis_length));
        var direction: i64 = 1;
        if (start_x > end_x) {
            // The Voronoi edge goes the other way.
            direction = -1;
            std.mem.swap(Point, &marking_start, &marking_end);
            std.mem.swap(i64, &marking_start_x, &marking_end_x);
        }
        var ret: std.ArrayList(Point) = .empty;
        try ret.append(a, start);
        var add_marking_start = marking_start_x * direction > start_x * direction;
        var add_marking_end = marking_end_x * direction > start_x * direction;
        // An integer step count, with the vertices spread evenly.
        const ab = end.sub(start);
        const ab_size = vSize(ab);
        const step_size = st.params.discretization_step_size;
        var step_count = @divTrunc(ab_size + @divTrunc(step_size, 2), step_size);
        // A point in the middle.
        if (@mod(step_count, 2) == 1) step_count += 1;
        var step: i64 = 1;
        while (step < step_count) : (step += 1) {
            const here = start.add(divP(mulP(ab, step), step_count));
            const x_here = projX(here, middle, x_axis_dir, x_axis_length);
            if (add_marking_start and marking_start_x * direction < x_here * direction) {
                try ret.append(a, marking_start);
                add_marking_start = false;
            }
            if (add_marking_end and marking_end_x * direction < x_here * direction) {
                try ret.append(a, marking_end);
                add_marking_end = false;
            }
            try ret.append(a, here);
        }
        if (add_marking_end and marking_end_x * direction < end_x * direction) try ret.append(a, marking_end);
        try ret.append(a, end);
        return ret.items;
    }

    /// The range of edges of a point cell, from the edge that leaves the
    /// point to the edge that comes back. False if the cell is outside the
    /// polygons (then no part of it goes into the graph).
    fn computePointCellRange(st: *SkeletalTrapezoidation, vd: *const voronoi.Diagram, cell: voronoi.Cell, start_source_point: *Point, end_source_point: *Point, starting_vd_edge: *?u32, ending_vd_edge: *?u32, polys: geom.Paths) bool {
        // A cell with no edges (a degenerate input) has no part in the graph.
        const first = cell.incident_edge orelse return false;
        // Infinite edges are only outside the polygons.
        if (vd.isInfinite(first)) return false;
        // The cell is all inside or all outside.
        const source_point = st.sourcePoint(cell);
        var some_point = vdPoint(vd, (vd.edges[first].vertex0 orelse return false));
        if (some_point.eql(source_point)) some_point = vdPoint(vd, (vd.vertex1(first) orelse return false));
        if (!geom.insideAny(polys, some_point)) return false;
        var e = first;
        while (true) {
            if (vd.isInfinite(e)) return false;
            const p1 = vdPoint(vd, (vd.vertex1(e) orelse return false));
            if (p1.eql(source_point)) {
                start_source_point.* = source_point;
                end_source_point.* = source_point;
                starting_vd_edge.* = vd.edges[e].next;
                ending_vd_edge.* = e;
            }
            e = vd.edges[e].next;
            if (e == first) break;
        }
        return starting_vd_edge.* != null and ending_vd_edge.* != null and starting_vd_edge.*.? != ending_vd_edge.*.?;
    }

    /// The range of edges of a segment cell on the inner side of the
    /// segment: from the edge that leaves its end to the edge that comes to
    /// its start.
    fn computeSegmentCellRange(st: *SkeletalTrapezoidation, vd: *const voronoi.Diagram, cell: voronoi.Cell, start_source_point: *Point, end_source_point: *Point, starting_vd_edge: *?u32, ending_vd_edge: *?u32) void {
        const source_segment = st.sourceSegment(cell);
        const from = source_segment.from;
        const to = source_segment.to;
        var seen_possible_start = false;
        var after_start = false;
        var ending_edge_is_set_before_start = false;
        // A cell with no edges: no range (the caller skips the cell).
        const first = cell.incident_edge orelse return;
        var e = first;
        while (true) {
            if (!vd.isInfinite(e)) {
                const v0 = vdPoint(vd, (vd.edges[e].vertex0 orelse return));
                const v1 = vdPoint(vd, (vd.vertex1(e) orelse return));
                if (v0.eql(to) and !after_start) {
                    // The last edge that starts at the end of the segment.
                    starting_vd_edge.* = e;
                    seen_possible_start = true;
                } else if (seen_possible_start) {
                    after_start = true;
                }
                if (v1.eql(from) and (ending_vd_edge.* == null or ending_edge_is_set_before_start)) {
                    ending_edge_is_set_before_start = !after_start;
                    ending_vd_edge.* = e;
                }
            }
            e = vd.edges[e].next;
            if (e == first) break;
        }
        if (starting_vd_edge.* != null and starting_vd_edge.* == ending_vd_edge.*) {
            starting_vd_edge.* = null;
        }
        start_source_point.* = to;
        end_source_point.* = from;
    }

    /// A node at the start of two quads (of a polygon vertex cell) splits
    /// in two, so that each quad start is the incident edge of its node.
    fn separatePointyQuadEndNodes(st: *SkeletalTrapezoidation) !void {
        var visited: std.AutoHashMapUnmanaged(*Node, void) = .empty;
        var i: usize = 0;
        while (i < st.edges.items.len) : (i += 1) {
            const edge = st.edges.items[i];
            if (edge.dead or edge.prev != null) continue;
            const gop = try visited.getOrPut(st.a, edge.from);
            if (!gop.found_existing) continue;
            // Duplicate the node.
            const new_node = try st.newNode(edge.from.p);
            new_node.* = edge.from.*;
            new_node.incident_edge = edge;
            edge.from = new_node;
            edge.twin.?.to = new_node;
        }
    }

    fn collapseSmallEdges(st: *SkeletalTrapezoidation, snap: i64) void {
        const shouldCollapse = struct {
            fn f(x: *const Node, y: *const Node, s: i64) bool {
                return shorterThan(x.p.sub(y.p), s);
            }
        }.f;
        var i: usize = 0;
        while (i < st.edges.items.len) : (i += 1) {
            const quad_start = st.edges.items[i];
            if (quad_start.dead or quad_start.prev != null) continue;
            var quad_end = quad_start;
            while (quad_end.next) |n| quad_end = n;
            const quad_mid: ?*Edge = if (quad_start.next == quad_end) null else quad_start.next;
            if (quad_mid) |qm| {
                if (shouldCollapse(qm.from, qm.to, snap)) collapse_top: {
                    const qmt = qm.twin orelse break :collapse_top;
                    // A degenerate graph can miss a link: then no collapse
                    // (checked before any change).
                    if (qm.prev == null or qm.next == null or qmt.next == null or qmt.prev == null) break :collapse_top;
                    var count: usize = 0;
                    var e3: ?*Edge = quad_end;
                    while (e3) |edge_from_3| {
                        if (edge_from_3 == qmt) break;
                        edge_from_3.from = qm.from;
                        const tw = edge_from_3.twin orelse break;
                        tw.to = qm.from;
                        count += 1;
                        if (count > 1000) break;
                        e3 = tw.next;
                    }
                    // o-o > collapse the top
                    // | |
                    // o o
                    if (qm.from.incident_edge == qm) {
                        qm.from.incident_edge = if (qmt.next) |n| n else qm.prev.?.twin;
                    }
                    qm.to.dead = true;
                    qm.prev.?.next = qm.next;
                    qm.next.?.prev = qm.prev;
                    qmt.next.?.prev = qmt.prev;
                    qmt.prev.?.next = qmt.next;
                    qmt.dead = true;
                    qm.dead = true;
                }
            }
            //  o-o
            //  | | > collapse the sides
            //  o o
            const sides_ok = quad_start.twin != null and quad_end.twin != null and (quad_end.twin.?.next != null or quad_end.prev != null);
            if (sides_ok and shouldCollapse(quad_start.from, quad_end.to, snap) and shouldCollapse(quad_start.to, quad_end.from, snap)) {
                // Remove the start and end edges, and the whole cell.
                quad_start.twin.?.to = quad_end.to;
                quad_end.to.incident_edge = quad_end.twin;
                if (quad_end.from.incident_edge == quad_end) {
                    quad_end.from.incident_edge = if (quad_end.twin.?.next) |n| n else quad_end.prev.?.twin;
                }
                quad_start.from.dead = true;
                quad_start.twin.?.twin = quad_end.twin;
                quad_end.twin.?.twin = quad_start.twin;
                quad_start.dead = true;
                quad_end.dead = true;
            }
        }
    }

    /// Adds a rib from the end of `prev_edge` to its closest point on the
    /// source segment (or the source point), there and back.
    fn makeRib(st: *SkeletalTrapezoidation, prev_edge: *?*Edge, start_source_point: Point, end_source_point: Point) !void {
        const pe = prev_edge.*.?;
        const p = closestOnLine(pe.to.p, start_source_point, end_source_point);
        const dist = vSize(pe.to.p.sub(p));
        pe.to.distance_to_boundary = dist;
        const node = try st.newNode(p);
        node.distance_to_boundary = 0;
        const forth_edge = try st.newEdge(.extra_vd);
        const back_edge = try st.newEdge(.extra_vd);
        pe.next = forth_edge;
        forth_edge.prev = pe;
        forth_edge.from = pe.to;
        forth_edge.to = node;
        forth_edge.twin = back_edge;
        back_edge.twin = forth_edge;
        back_edge.from = node;
        back_edge.to = pe.to;
        node.incident_edge = back_edge;
        prev_edge.* = back_edge;
    }

    /// The two edges that replace `edge`, with a rib from `mid_node` to the
    /// outline between them.
    fn insertRib(st: *SkeletalTrapezoidation, edge: *Edge, mid_node: *Node) ![2]*Edge {
        const edge_before = edge.prev;
        const edge_after = edge.next;
        const node_before = edge.from;
        const node_after = edge.to;
        const p = mid_node.p;
        const source = getSource(edge);
        const px = closestOnLineSegment(p, source[0], source[1]);
        const dist = vSize(p.sub(px));
        mid_node.distance_to_boundary = dist;
        // Both ends of a transition have a whole number of beads.
        mid_node.transition_ratio = 0;
        const source_node = try st.newNode(px);
        source_node.distance_to_boundary = 0;
        const first = edge;
        const second = try st.newEdge(.normal);
        const outward_edge = try st.newEdge(.transition_end);
        const inward_edge = try st.newEdge(.transition_end);
        if (edge_before) |eb| eb.next = first;
        first.next = outward_edge;
        outward_edge.next = null;
        inward_edge.next = second;
        second.next = edge_after;
        if (edge_after) |ea| ea.prev = second;
        second.prev = inward_edge;
        inward_edge.prev = null;
        outward_edge.prev = first;
        first.prev = edge_before;
        first.to = mid_node;
        outward_edge.to = source_node;
        inward_edge.to = mid_node;
        second.to = node_after;
        first.from = node_before;
        outward_edge.from = mid_node;
        inward_edge.from = source_node;
        second.from = mid_node;
        node_before.incident_edge = first;
        mid_node.incident_edge = outward_edge;
        source_node.incident_edge = inward_edge;
        if (edge_after != null) node_after.incident_edge = edge_after;
        first.setIsCentral(true);
        outward_edge.setIsCentral(false);
        inward_edge.setIsCentral(false);
        second.setIsCentral(true);
        outward_edge.twin = inward_edge;
        inward_edge.twin = outward_edge;
        first.twin = null;
        second.twin = null;
        return .{ first, second };
    }

    /// Splits `edge` and its twin at `mid`. Returns the new edge after the
    /// new node.
    fn insertNode(st: *SkeletalTrapezoidation, edge: *Edge, mid: Point, mid_node_bead_count: i64) !*Edge {
        const mid_node = try st.newNode(mid);
        const twin = edge.twin.?;
        edge.twin = null;
        twin.twin = null;
        const left_pair = try st.insertRib(edge, mid_node);
        const right_pair = try st.insertRib(twin, mid_node);
        const first_edge_replacing_input = left_pair[0];
        const last_edge_replacing_input = left_pair[1];
        const first_edge_replacing_twin = right_pair[0];
        const last_edge_replacing_twin = right_pair[1];
        first_edge_replacing_input.twin = last_edge_replacing_twin;
        last_edge_replacing_twin.twin = first_edge_replacing_input;
        last_edge_replacing_input.twin = first_edge_replacing_twin;
        first_edge_replacing_twin.twin = last_edge_replacing_input;
        mid_node.bead_count = mid_node_bead_count;
        return last_edge_replacing_input;
    }

    /// The source segment of the quad of `edge`: the start of its first
    /// edge and the end of its last edge.
    fn getSource(edge: *const Edge) [2]Point {
        var from_edge = edge;
        while (from_edge.prev) |p| from_edge = p;
        var to_edge = edge;
        while (to_edge.next) |n| to_edge = n;
        return .{ from_edge.from.p, to_edge.to.p };
    }

    // ---------------------------------------------------------------
    // Transitions
    // ---------------------------------------------------------------

    /// Makes the toolpaths. `out` gets one list of lines for each wall.
    pub fn generateToolpaths(st: *SkeletalTrapezoidation, out: *std.ArrayList(Lines), filter_outermost_central_edges: bool) !void {
        st.out = out;
        st.updateIsCentral();
        st.filterCentral(central_filter_dist);
        if (filter_outermost_central_edges) st.filterOuterCentral();
        st.updateBeadCount();
        st.filterNoncentralRegions();
        try st.generateTransitioningRibs();
        try st.generateExtraRibs();
        try st.generateSegments();
    }

    fn updateIsCentral(st: *SkeletalTrapezoidation) void {
        //                                            _.-'^`      A and B are the ends of the edge.
        //                                      _.-'^`            A part of AB is a cap, because
        //                                _.-'^` \                the polygon is too narrow there.
        //                          _.-'^`        \               If |AB| minus the cap is still
        //                    _.-'^`               \ R2           larger than dR, AB is central.
        //              _.-'^` \              _.-'\`\
        //        _.-'^`        \R1     _.-'^`     '`\ dR
        //  _.-'^`a/2            \_.-'^`a             \           AR2 is parallel to the outline.
        //  `^'-._````````````````A```````````v````````B```````   dR is the rest of the diameter at B.
        //        `^'-._                     dD = |AB|            An obtuse corner gives fewer
        //              `^'-._                                    central edges.
        //                             sin a = dR / dD
        const outer_edge_filter_length = @divTrunc(st.strategy.getTransitionThickness(0), 2);
        const cap = @sin(st.strategy.getTransitioningAngle() * 0.5);
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            const twin = edge.twin orelse continue;
            if (twin.centralIsSet()) {
                edge.setIsCentral(twin.isCentral());
            } else if (edge.type == .extra_vd) {
                edge.setIsCentral(false);
            } else if (@max(edge.from.distance_to_boundary, edge.to.distance_to_boundary) < outer_edge_filter_length) {
                edge.setIsCentral(false);
            } else {
                const dR: i64 = @intCast(@abs(edge.to.distance_to_boundary - edge.from.distance_to_boundary));
                const dD = vSize(edge.to.p.sub(edge.from.p));
                edge.setIsCentral(@as(f64, @floatFromInt(dR)) < @as(f64, @floatFromInt(dD)) * cap);
            }
        }
    }

    fn filterCentral(st: *SkeletalTrapezoidation, max_length: i64) void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            // As in CuraEngine, the condition is never true: the to node is
            // a local maximum and not a local maximum.
            if (st.isEndOfCentral(edge) and edge.to.isLocalMaximum(false) and !edge.to.isLocalMaximum(false)) {
                _ = st.filterCentralFrom(edge.twin.?, 0, max_length);
            }
        }
    }

    fn filterCentralFrom(st: *SkeletalTrapezoidation, starting_edge: *Edge, traveled_dist: i64, max_length: i64) bool {
        const length = vSize(starting_edge.from.p.sub(starting_edge.to.p));
        if (traveled_dist + length > max_length) return false;
        var should_dissolve = true;
        var ne = starting_edge.next;
        while (ne) |next_edge| {
            if (next_edge == starting_edge.twin) break;
            if (next_edge.isCentral()) should_dissolve = st.filterCentralFrom(next_edge, traveled_dist + length, max_length) and should_dissolve;
            ne = next_edge.twin.?.next;
        }
        // Keep central regions with a local maximum.
        should_dissolve = should_dissolve and !starting_edge.to.isLocalMaximum(false);
        if (should_dissolve) {
            starting_edge.setIsCentral(false);
            starting_edge.twin.?.setIsCentral(false);
        }
        return should_dissolve;
    }

    fn filterOuterCentral(st: *SkeletalTrapezoidation) void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            if (edge.prev == null) {
                edge.setIsCentral(false);
                edge.twin.?.setIsCentral(false);
            }
        }
    }

    fn updateBeadCount(st: *SkeletalTrapezoidation) void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            if (edge.isCentral()) edge.to.bead_count = st.strategy.getOptimalBeadCount(edge.to.distance_to_boundary * 2);
        }
        // The bead count at a local maximum of R, also for central regions.
        for (st.nodes.items) |node| {
            if (node.dead) continue;
            if (node.isLocalMaximum(false)) {
                if (node.distance_to_boundary < 0) {
                    node.distance_to_boundary = std.math.maxInt(i64);
                    const first = node.incident_edge.?;
                    var edge = first;
                    while (true) {
                        node.distance_to_boundary = @min(node.distance_to_boundary, edge.to.distance_to_boundary + vSize(edge.from.p.sub(edge.to.p)));
                        edge = edge.twin.?.next orelse break;
                        if (edge == first) break;
                    }
                }
                node.bead_count = st.strategy.getOptimalBeadCount(node.distance_to_boundary * 2);
            }
        }
    }

    fn filterNoncentralRegions(st: *SkeletalTrapezoidation) void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            if (!st.isEndOfCentral(edge)) continue;
            const max_dist: i64 = 400;
            _ = st.filterNoncentralRegionsFrom(edge, edge.to.bead_count, 0, max_dist);
        }
    }

    fn filterNoncentralRegionsFrom(st: *SkeletalTrapezoidation, to_edge: *Edge, bead_count: i64, traveled_dist: i64, max_dist: i64) bool {
        const r = to_edge.to.distance_to_boundary;
        var next_edge = to_edge.next;
        while (next_edge) |ne| {
            if (ne == to_edge.twin) break;
            // Only walk upward.
            if (ne.to.distance_to_boundary >= r or shorterThan(ne.to.p.sub(ne.from.p), 10)) break;
            next_edge = ne.twin.?.next;
        }
        const ne = next_edge orelse return false;
        if (ne == to_edge.twin) return false;
        const length = vSize(ne.to.p.sub(ne.from.p));
        var dissolve = false;
        if (ne.to.bead_count == bead_count) {
            dissolve = true;
        } else if (ne.to.bead_count < 0) {
            dissolve = st.filterNoncentralRegionsFrom(ne, bead_count, traveled_dist + length, max_dist);
        } else {
            // Two central regions with a different bead count closer than
            // the transition distance.
            dissolve = (traveled_dist + length < max_dist) and @abs(ne.to.bead_count - bead_count) == 1;
        }
        if (dissolve) {
            ne.setIsCentral(true);
            ne.twin.?.setIsCentral(true);
            ne.to.bead_count = st.strategy.getOptimalBeadCount(ne.to.distance_to_boundary * 2);
            ne.to.transition_ratio = 0;
        }
        return dissolve;
    }

    fn generateTransitioningRibs(st: *SkeletalTrapezoidation) !void {
        try st.generateTransitionMids();
        try st.filterTransitionMids();
        for (st.edges.items) |e| {
            if (e.transitions) |t| {
                // Drop the removed transitions.
                var k: usize = 0;
                for (t.items) |m| {
                    if (m.dead) continue;
                    t.items[k] = m;
                    k += 1;
                }
                t.shrinkRetainingCapacity(k);
            }
        }
        try st.generateAllTransitionEnds();
        try st.applyTransitions();
        // In CuraEngine the lists go out of scope here: only weak pointers
        // refer to them.
        for (st.edges.items) |e| {
            e.transitions = null;
            e.transition_ends = null;
        }
    }

    fn generateTransitionMids(st: *SkeletalTrapezoidation) !void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            // Only central regions get transitions.
            if (!edge.isCentral()) continue;
            const start_R = edge.from.distance_to_boundary;
            const end_R = edge.to.distance_to_boundary;
            const start_bead_count = edge.from.bead_count;
            const end_bead_count = edge.to.bead_count;
            // No transitions on a flat edge, and only on the half-edges that
            // go up.
            if (start_R == end_R) continue;
            if (start_R > end_R) continue;
            if (start_bead_count == end_bead_count) continue;
            const edge_size = vSize(edge.from.p.sub(edge.to.p));
            var lower = start_bead_count;
            while (lower < end_bead_count) : (lower += 1) {
                var mid_R = @divTrunc(st.strategy.getTransitionThickness(lower), 2);
                if (mid_R > end_R) mid_R = end_R;
                if (mid_R < start_R) mid_R = start_R;
                const mid_pos = @divTrunc(edge_size * (mid_R - start_R), end_R - start_R);
                if (!edge.hasTransitions(true)) {
                    const t = try st.a.create(Transitions);
                    t.* = .empty;
                    edge.transitions = t;
                }
                try edge.transitions.?.append(st.a, .{ .pos = mid_pos, .lower_bead_count = lower, .feature_radius = mid_R });
            }
        }
    }

    fn filterTransitionMids(st: *SkeletalTrapezoidation) Allocator.Error!void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            if (!edge.hasTransitions(false)) continue;
            const transitions = edge.transitions.?;
            const ab_size = vSize(edge.to.p.sub(edge.from.p));

            var back = lastLive(transitions).?;
            var going_up = true;
            var to_be_dissolved_back: std.ArrayList(*TransitionMiddle) = .empty;
            try st.dissolveNearbyTransitions(edge, back.*, ab_size - back.pos, st.params.transition_filter_dist, going_up, &to_be_dissolved_back);
            var should_dissolve_back = to_be_dissolved_back.items.len > 0;
            for (to_be_dissolved_back.items) |ref| {
                st.dissolveBeadCountRegion(edge, back.lower_bead_count + 1, back.lower_bead_count);
                ref.dead = true;
            }
            back = lastLive(transitions) orelse continue;
            {
                const trans_bead_count = back.lower_bead_count;
                const upper_transition_half_length = beading_mod.trunc((1.0 - st.strategy.getTransitionAnchorPos(trans_bead_count)) * @as(f64, @floatFromInt(st.strategy.getTransitioningLength(trans_bead_count))));
                should_dissolve_back = st.filterEndOfCentralTransition(edge, ab_size - back.pos, upper_transition_half_length, trans_bead_count) or should_dissolve_back;
            }
            if (should_dissolve_back) back.dead = true;
            // `filterEndOfCentralTransition` gives inconsistent bead counts
            // when it runs for the same transition in both directions.
            var front = firstLive(transitions) orelse continue;

            going_up = false;
            var to_be_dissolved_front: std.ArrayList(*TransitionMiddle) = .empty;
            try st.dissolveNearbyTransitions(edge.twin.?, front.*, front.pos, st.params.transition_filter_dist, going_up, &to_be_dissolved_front);
            var should_dissolve_front = to_be_dissolved_front.items.len > 0;
            for (to_be_dissolved_front.items) |ref| {
                st.dissolveBeadCountRegion(edge.twin.?, front.lower_bead_count, front.lower_bead_count + 1);
                ref.dead = true;
            }
            front = firstLive(transitions) orelse continue;
            {
                const trans_bead_count = front.lower_bead_count;
                const lower_transition_half_length = beading_mod.trunc(st.strategy.getTransitionAnchorPos(trans_bead_count) * @as(f64, @floatFromInt(st.strategy.getTransitioningLength(trans_bead_count))));
                should_dissolve_front = st.filterEndOfCentralTransition(edge.twin.?, front.pos, lower_transition_half_length, trans_bead_count + 1) or should_dissolve_front;
            }
            if (should_dissolve_front) front.dead = true;
        }
    }

    /// The transitions near `origin_transition` that cancel it out. The
    /// result goes in `out` (empty if the origin stays).
    fn dissolveNearbyTransitions(st: *SkeletalTrapezoidation, edge_to_start: *Edge, origin_transition: TransitionMiddle, traveled_dist: i64, max_dist: i64, going_up: bool, out: *std.ArrayList(*TransitionMiddle)) Allocator.Error!void {
        if (traveled_dist > max_dist) return;
        const out_start = out.items.len;
        var should_dissolve = true;
        var oe = edge_to_start.next;
        while (oe) |edge| : (oe = edge.twin.?.next) {
            if (edge == edge_to_start.twin) break;
            if (!edge.isCentral()) continue;
            const ab_size = vSize(edge.to.p.sub(edge.from.p));
            const is_aligned = edge.isUpward();
            const aligned_edge = if (is_aligned) edge else edge.twin.?;
            var seen_transition_on_this_edge = false;
            const origin_radius = origin_transition.feature_radius;
            const radius_here = edge.from.distance_to_boundary;
            const dissolve_result_is_odd = (@mod(origin_transition.lower_bead_count, 2) == 1) == going_up;
            // Times two: the deviation is on both sides of the edge.
            const width_deviation: i64 = @as(i64, @intCast(@abs(origin_radius - radius_here))) * 2;
            // The deviation spreads over 1 or 2 lines.
            const line_width_deviation = if (dissolve_result_is_odd) width_deviation else @divTrunc(width_deviation, 2);
            if (line_width_deviation > st.params.allowed_filter_deviation) should_dissolve = false;
            if (should_dissolve and aligned_edge.hasTransitions(false)) {
                for (aligned_edge.transitions.?.items) |*t| {
                    if (t.dead) continue;
                    // This is not always in the direction of travel.
                    const pos = if (is_aligned) t.pos else ab_size - t.pos;
                    // Only dissolve local optima.
                    if (traveled_dist + pos < max_dist and t.lower_bead_count == origin_transition.lower_bead_count) {
                        try out.append(st.a, t);
                        seen_transition_on_this_edge = true;
                    }
                }
            }
            if (should_dissolve and !seen_transition_on_this_edge) {
                const before = out.items.len;
                try st.dissolveNearbyTransitions(edge, origin_transition, traveled_dist + ab_size, max_dist, going_up, out);
                if (out.items.len == before) {
                    // The region is too long to dissolve in this direction,
                    // so it cannot dissolve in any direction.
                    out.shrinkRetainingCapacity(out_start);
                    return;
                }
                should_dissolve = should_dissolve and out.items.len > out_start;
            }
        }
        if (!should_dissolve) out.shrinkRetainingCapacity(out_start);
    }

    fn dissolveBeadCountRegion(st: *SkeletalTrapezoidation, edge_to_start: *Edge, from_bead_count: i64, to_bead_count: i64) void {
        if (edge_to_start.to.bead_count != from_bead_count) return;
        edge_to_start.to.bead_count = to_bead_count;
        var oe = edge_to_start.next;
        while (oe) |edge| : (oe = edge.twin.?.next) {
            if (edge == edge_to_start.twin) break;
            if (!edge.isCentral()) continue;
            st.dissolveBeadCountRegion(edge, from_bead_count, to_bead_count);
        }
    }

    fn filterEndOfCentralTransition(st: *SkeletalTrapezoidation, edge_to_start: *Edge, traveled_dist: i64, max_dist: i64, replacing_bead_count: i64) bool {
        if (traveled_dist > max_dist) return false;
        var is_end_of_central = true;
        var should_dissolve = false;
        var oe = edge_to_start.next;
        while (oe) |next_edge| : (oe = next_edge.twin.?.next) {
            if (next_edge == edge_to_start.twin) break;
            if (next_edge.isCentral()) {
                const length = vSize(next_edge.to.p.sub(next_edge.from.p));
                should_dissolve = st.filterEndOfCentralTransition(next_edge, traveled_dist + length, max_dist, replacing_bead_count) or should_dissolve;
                is_end_of_central = false;
            }
        }
        if (is_end_of_central and traveled_dist < max_dist) should_dissolve = true;
        if (should_dissolve) edge_to_start.to.bead_count = replacing_bead_count;
        return should_dissolve;
    }

    fn generateAllTransitionEnds(st: *SkeletalTrapezoidation) !void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            if (!edge.hasTransitions(false)) continue;
            for (edge.transitions.?.items) |m| {
                try st.generateTransitionEnds(edge, m.pos, m.lower_bead_count);
            }
        }
    }

    fn generateTransitionEnds(st: *SkeletalTrapezoidation, edge: *Edge, mid_pos: i64, lower_bead_count: i64) !void {
        const ab_size = vSize(edge.to.p.sub(edge.from.p));
        const transition_length: f64 = @floatFromInt(st.strategy.getTransitioningLength(lower_bead_count));
        const transition_mid_position = st.strategy.getTransitionAnchorPos(lower_bead_count);
        const inner_bead_width_ratio_after_transition: f64 = 1.0;
        const start_rest: f64 = 0.0;
        const mid_rest = transition_mid_position * inner_bead_width_ratio_after_transition;
        const end_rest = inner_bead_width_ratio_after_transition;
        {
            // The end with the lower bead count.
            const start_pos = ab_size - mid_pos;
            const transition_half_length = beading_mod.trunc(transition_mid_position * transition_length);
            const end_pos = start_pos + transition_half_length;
            _ = try st.generateTransitionEnd(edge.twin.?, start_pos, end_pos, transition_half_length, mid_rest, start_rest, lower_bead_count);
        }
        {
            // The end with the upper bead count.
            const start_pos = mid_pos;
            const transition_half_length = beading_mod.trunc((1.0 - transition_mid_position) * transition_length);
            const end_pos = mid_pos + transition_half_length;
            _ = try st.generateTransitionEnd(edge, start_pos, end_pos, transition_half_length, mid_rest, end_rest, lower_bead_count);
        }
    }

    /// Returns whether the edge goes down (to a narrower part).
    fn generateTransitionEnd(st: *SkeletalTrapezoidation, edge: *Edge, start_pos: i64, end_pos: i64, transition_half_length: i64, start_rest: f64, end_rest: f64, lower_bead_count: i64) Allocator.Error!bool {
        const ab_size = vSize(edge.to.p.sub(edge.from.p));
        const going_up = end_rest > start_rest;
        // No ends in or past non-central regions.
        if (!edge.isCentral()) return false;
        if (end_pos > ab_size) {
            // Recurse on all further edges.
            const rest = end_rest - (start_rest - end_rest) * @as(f64, @floatFromInt(end_pos - ab_size)) / @as(f64, @floatFromInt(start_pos - end_pos));
            var central_edge_count: usize = 0;
            var oe = edge.next;
            while (oe) |outgoing| : (oe = outgoing.twin.?.next) {
                if (outgoing == edge.twin) break;
                if (outgoing.isCentral()) central_edge_count += 1;
            }
            var is_only_going_down = true;
            var has_recursed = false;
            oe = edge.next;
            while (oe) |outgoing| {
                if (outgoing == edge.twin) break;
                // Read the next one before the outgoing edge changes.
                const next = outgoing.twin.?.next;
                defer oe = next;
                // No transition ends in non-central regions.
                if (!outgoing.isCentral()) continue;
                // After a 3-way junction of central edges, in the direction
                // of the lower bead count: no transition end in this
                // direction, as the transition goes up.
                if (central_edge_count > 1 and going_up and st.isGoingDown(outgoing, 0, end_pos - ab_size + transition_half_length, lower_bead_count)) continue;
                const is_going_down = try st.generateTransitionEnd(outgoing, 0, end_pos - ab_size, transition_half_length, rest, end_rest, lower_bead_count);
                is_only_going_down = is_only_going_down and is_going_down;
                has_recursed = true;
            }
            if (!going_up or (has_recursed and !is_only_going_down)) {
                edge.to.transition_ratio = rest;
                edge.to.bead_count = lower_bead_count;
            }
            return is_only_going_down;
        }
        // The end is on this edge.
        const is_lower_end = end_rest == 0;
        var pos: i64 = -1;
        var upward_edge: *Edge = undefined;
        if (edge.isUpward()) {
            upward_edge = edge;
            pos = end_pos;
        } else {
            upward_edge = edge.twin.?;
            pos = ab_size - end_pos;
        }
        if (!upward_edge.hasTransitionEnds(true)) {
            const t = try st.a.create(TransitionEnds);
            t.* = .empty;
            upward_edge.transition_ends = t;
        }
        const ends = upward_edge.transition_ends.?;
        // Pre-sort: a lower position goes to the front.
        if (ends.items.len == 0 or pos < ends.items[0].pos) {
            try ends.insert(st.a, 0, .{ .pos = pos, .lower_bead_count = lower_bead_count, .is_lower_end = is_lower_end });
        } else {
            try ends.append(st.a, .{ .pos = pos, .lower_bead_count = lower_bead_count, .is_lower_end = is_lower_end });
        }
        return false;
    }

    /// True if the edge goes down (to a narrower part of the polygon).
    fn isGoingDown(st: *SkeletalTrapezoidation, outgoing: *Edge, traveled_dist: i64, max_dist: i64, lower_bead_count: i64) bool {
        // CuraEngine: the logic is not fully thought through, and does not
        // look at the transition mids.
        if (outgoing.to.distance_to_boundary == 0) return true;
        const is_upward = outgoing.to.distance_to_boundary >= outgoing.from.distance_to_boundary;
        const upward_edge = if (is_upward) outgoing else outgoing.twin.?;
        // If the bead count goes down, there is a transition mid.
        if (outgoing.to.bead_count > lower_bead_count + 1) return false;
        const length = vSize(outgoing.to.p.sub(outgoing.from.p));
        if (upward_edge.hasTransitions(false)) {
            const t = upward_edge.transitions.?;
            const mid = if (is_upward) firstLive(t).? else lastLive(t).?;
            if (mid.lower_bead_count == lower_bead_count and ((is_upward and mid.pos + traveled_dist < max_dist) or (!is_upward and length - mid.pos + traveled_dist < max_dist))) return true;
        }
        if (traveled_dist + length > max_dist) return false;
        if (outgoing.to.bead_count <= lower_bead_count and !(outgoing.to.bead_count == lower_bead_count and outgoing.to.transition_ratio > 0.0)) return true;
        var is_only_going_down = true;
        var has_recursed = false;
        var ne = outgoing.next;
        while (ne) |next| : (ne = next.twin.?.next) {
            if (next == outgoing.twin) break;
            if (!next.isCentral()) continue;
            const is_going_down = st.isGoingDown(next, traveled_dist + length, max_dist, lower_bead_count);
            is_only_going_down = is_only_going_down and is_going_down;
            has_recursed = true;
        }
        return has_recursed and is_only_going_down;
    }

    fn applyTransitions(st: *SkeletalTrapezoidation) !void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            const twin = edge.twin orelse continue;
            if (twin.hasTransitionEnds(false)) {
                const length = vSize(edge.from.p.sub(edge.to.p));
                const twin_ends = twin.transition_ends.?;
                if (!edge.hasTransitionEnds(true)) {
                    const t = try st.a.create(TransitionEnds);
                    t.* = .empty;
                    edge.transition_ends = t;
                }
                for (twin_ends.items) |end| {
                    try edge.transition_ends.?.append(st.a, .{ .pos = length - end.pos, .lower_bead_count = end.lower_bead_count, .is_lower_end = end.is_lower_end });
                }
                twin_ends.clearRetainingCapacity();
            }
        }
        var i: usize = 0;
        while (i < st.edges.items.len) : (i += 1) {
            const edge = st.edges.items[i];
            if (edge.dead) continue;
            if (!edge.hasTransitionEnds(false)) continue;
            const transitions = edge.transition_ends.?;
            std.mem.sort(TransitionEnd, transitions.items, {}, struct {
                fn lt(_: void, x: TransitionEnd, y: TransitionEnd) bool {
                    return x.pos < y.pos;
                }
            }.lt);
            const from = edge.from;
            const to = edge.to;
            const a_p = from.p;
            const ab = to.p.sub(from.p);
            const ab_size = vSize(ab);
            var last_edge_replacing_input = edge;
            for (transitions.items) |transition_end| {
                const new_node_bead_count = if (transition_end.is_lower_end) transition_end.lower_bead_count else transition_end.lower_bead_count + 1;
                const end_pos = transition_end.pos;
                const close_node = if (end_pos < @divTrunc(ab_size, 2)) from else to;
                if ((end_pos < snap_dist or end_pos > ab_size - snap_dist) and close_node.bead_count == new_node_bead_count) {
                    close_node.transition_ratio = 0;
                    continue;
                }
                const mid = a_p.add(normal(ab, end_pos));
                last_edge_replacing_input = try st.insertNode(last_edge_replacing_input, mid, new_node_bead_count);
            }
        }
    }

    fn isEndOfCentral(st: *const SkeletalTrapezoidation, edge_to: *const Edge) bool {
        _ = st;
        if (!edge_to.isCentral()) return false;
        if (edge_to.next == null) return true;
        var oe = edge_to.next;
        while (oe) |edge| : (oe = edge.twin.?.next) {
            if (edge == edge_to.twin) break;
            if (edge.isCentral()) return false;
        }
        return true;
    }

    fn generateExtraRibs(st: *SkeletalTrapezoidation) !void {
        var i: usize = 0;
        while (i < st.edges.items.len) : (i += 1) {
            const edge = st.edges.items[i];
            if (edge.dead) continue;
            if (!edge.isCentral() or shorterThan(edge.to.p.sub(edge.from.p), st.params.discretization_step_size) or edge.from.distance_to_boundary >= edge.to.distance_to_boundary) continue;
            var buf: [4]i64 = undefined;
            const rib_thicknesses = st.strategy.getNonlinearThicknesses(edge.from.bead_count, &buf);
            if (rib_thicknesses.len == 0) continue;
            // Keep some values before `edge` changes.
            const from = edge.from;
            const to = edge.to;
            const a_p = from.p;
            const ab = to.p.sub(from.p);
            const ab_size = vSize(ab);
            const a_R = edge.from.distance_to_boundary;
            const b_R = edge.to.distance_to_boundary;
            var last_edge_replacing_input = edge;
            for (rib_thicknesses) |rib_thickness| {
                if (@divTrunc(rib_thickness, 2) <= a_R) continue;
                if (@divTrunc(rib_thickness, 2) >= b_R) break;
                const new_node_bead_count = @min(edge.from.bead_count, edge.to.bead_count);
                const end_pos = @divTrunc(ab_size * (@divTrunc(rib_thickness, 2) - a_R), b_R - a_R);
                const close_node = if (end_pos < @divTrunc(ab_size, 2)) from else to;
                if ((end_pos < snap_dist or end_pos > ab_size - snap_dist) and close_node.bead_count == new_node_bead_count) {
                    close_node.transition_ratio = 0;
                    continue;
                }
                const mid = a_p.add(normal(ab, end_pos));
                last_edge_replacing_input = try st.insertNode(last_edge_replacing_input, mid, new_node_bead_count);
            }
        }
    }

    // ---------------------------------------------------------------
    // Toolpaths
    // ---------------------------------------------------------------

    fn generateSegments(st: *SkeletalTrapezoidation) !void {
        const a = st.a;
        var upward_quad_mids: std.ArrayList(*Edge) = .empty;
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            if (edge.prev != null and edge.next != null and edge.isUpward()) try upward_quad_mids.append(a, edge);
        }
        // A stable sort, as `std::stable_sort`.
        std.mem.sort(*Edge, upward_quad_mids.items, {}, quadMidLessThan);

        // Store the beadings.
        for (st.nodes.items) |node| {
            if (node.dead) continue;
            if (node.bead_count <= 0) continue;
            const bp = try a.create(BeadingPropagation);
            if (node.transition_ratio == 0) {
                bp.* = .{ .beading = try st.strategy.compute(a, node.distance_to_boundary * 2, node.bead_count) };
            } else {
                const low_count_beading = try st.strategy.compute(a, node.distance_to_boundary * 2, node.bead_count);
                const high_count_beading = try st.strategy.compute(a, node.distance_to_boundary * 2, node.bead_count + 1);
                bp.* = .{ .beading = try st.interpolate(low_count_beading, 1.0 - node.transition_ratio, high_count_beading) };
            }
            node.beading = bp;
        }
        try st.propagateBeadingsUpward(upward_quad_mids.items);
        try st.propagateBeadingsDownward(upward_quad_mids.items);
        try st.generateJunctions();
        try st.connectJunctions();
        try st.generateLocalMaximaSingleBeads();
    }

    fn quadMidLessThan(_: void, a: *Edge, b: *Edge) bool {
        if (a.to.distance_to_boundary == b.to.distance_to_boundary) {
            // The order of two upward edges of the same R matters when one
            // of them is flat and connects to the other.
            const a_flat = a.from.distance_to_boundary == a.to.distance_to_boundary;
            const b_flat = b.from.distance_to_boundary == b.to.distance_to_boundary;
            if (a_flat and b_flat) {
                const max = std.math.maxInt(i64);
                const a_dist_from_up = @min(a.distToGoUp() orelse max, a.twin.?.distToGoUp() orelse max) -% vSize(a.to.p.sub(a.from.p));
                const b_dist_from_up = @min(b.distToGoUp() orelse max, b.twin.?.distToGoUp() orelse max) -% vSize(b.to.p.sub(b.from.p));
                return a_dist_from_up < b_dist_from_up;
            } else if (a_flat) {
                // Edge a can be above edge b.
                return true;
            } else if (b_flat) {
                return false;
            }
        }
        return a.to.distance_to_boundary > b.to.distance_to_boundary;
    }

    /// From a quad, the edge to the node farthest from the outline.
    fn getQuadMaxRedgeTo(quad_start_edge: *Edge) *Edge {
        var max_R: i64 = -1;
        var ret: ?*Edge = null;
        var oe: ?*Edge = quad_start_edge;
        while (oe) |edge| : (oe = edge.next) {
            const r = edge.to.distance_to_boundary;
            if (r > max_R) {
                max_R = r;
                ret = edge;
            }
        }
        var r = ret.?;
        if (r.next == null and r.to.distance_to_boundary - 5 < r.from.distance_to_boundary) r = r.prev.?;
        return r;
    }

    fn propagateBeadingsUpward(st: *SkeletalTrapezoidation, upward_quad_mids: []const *Edge) !void {
        var i = upward_quad_mids.len;
        while (i > 0) {
            i -= 1;
            const upward_edge = upward_quad_mids[i];
            // Do not change a local beading.
            if (upward_edge.to.bead_count >= 0) continue;
            // Only propagate a beading.
            const lower_beading = upward_edge.from.beading orelse continue;
            // Only propagate to a place that has room.
            if (upward_edge.to.hasBeading()) continue;
            const length = vSize(upward_edge.to.p.sub(upward_edge.from.p));
            const upper = try st.a.create(BeadingPropagation);
            upper.* = lower_beading.*;
            upper.dist_to_bottom_source += length;
            upper.is_upward_propagated_only = true;
            upward_edge.to.beading = upper;
        }
    }

    fn propagateBeadingsDownward(st: *SkeletalTrapezoidation, upward_quad_mids: []const *Edge) !void {
        for (upward_quad_mids) |upward_quad_mid| {
            // Give the beading to the lower nodes.
            if (!upward_quad_mid.isCentral()) {
                // A flat edge: from the known beading to the node with none.
                if (upward_quad_mid.from.distance_to_boundary == upward_quad_mid.to.distance_to_boundary and upward_quad_mid.from.hasBeading() and !upward_quad_mid.to.hasBeading()) {
                    try st.propagateBeadingsDownwardEdge(upward_quad_mid.twin.?);
                } else {
                    try st.propagateBeadingsDownwardEdge(upward_quad_mid);
                }
            }
        }
    }

    fn propagateBeadingsDownwardEdge(st: *SkeletalTrapezoidation, edge_to_peak: *Edge) !void {
        const length = vSize(edge_to_peak.to.p.sub(edge_to_peak.from.p));
        const top_beading = try st.getOrCreateBeading(edge_to_peak.to);
        if (edge_to_peak.from.beading) |bottom_beading| {
            const total_dist = top_beading.dist_from_top_source + length + bottom_beading.dist_to_bottom_source;
            var ratio_of_top = @as(f64, @floatFromInt(bottom_beading.dist_to_bottom_source)) / @as(f64, @floatFromInt(@min(total_dist, st.params.beading_propagation_transition_dist)));
            ratio_of_top = @max(0.0, ratio_of_top);
            if (ratio_of_top >= 1.0) {
                bottom_beading.* = top_beading.*;
                bottom_beading.dist_from_top_source += length;
            } else {
                const merged = try st.interpolateSwitch(top_beading.beading, ratio_of_top, bottom_beading.beading, edge_to_peak.from.distance_to_boundary);
                bottom_beading.* = .{ .beading = merged };
                bottom_beading.is_upward_propagated_only = false;
            }
        } else {
            // A new beading for a node with none.
            const propagated = try st.a.create(BeadingPropagation);
            propagated.* = top_beading.*;
            propagated.dist_from_top_source += length;
            edge_to_peak.from.beading = propagated;
        }
    }

    /// The beading between two beadings. If one inset vanishes between
    /// `left` and the result (at `switching_radius`), the ratio moves so that
    /// it stays.
    fn interpolateSwitch(st: *SkeletalTrapezoidation, left: Beading, ratio_left_to_whole: f64, right: Beading, switching_radius: i64) !Beading {
        const ret = try st.interpolate(left, ratio_left_to_whole, right);
        var next_inset_idx: i64 = @as(i64, @intCast(left.toolpath_locations.len)) - 1;
        while (next_inset_idx >= 0) : (next_inset_idx -= 1) {
            if (switching_radius > left.toolpath_locations[@intCast(next_inset_idx)]) break;
        }
        // No next inset: there is only one.
        if (next_inset_idx < 0) return ret;
        // No previous inset to fit the next edge to.
        if (next_inset_idx + 1 == @as(i64, @intCast(left.toolpath_locations.len))) return ret;
        const k: usize = @intCast(next_inset_idx);
        if (ret.toolpath_locations[k] > switching_radius) {
            // An inset vanished between left and the merged beading. Solve
            // f l + (1 - f) r = s for f: f = (s - r) / (l - r).
            var new_ratio = @as(f64, @floatFromInt(switching_radius - right.toolpath_locations[k])) / @as(f64, @floatFromInt(left.toolpath_locations[k] - right.toolpath_locations[k]));
            new_ratio = @min(1.0, new_ratio + 0.1);
            return st.interpolate(left, new_ratio, right);
        }
        return ret;
    }

    /// The beading between two beadings with the same number of beads.
    fn interpolate(st: *SkeletalTrapezoidation, left: Beading, ratio_left_to_whole: f64, right: Beading) !Beading {
        const ratio_right_to_whole = 1.0 - ratio_left_to_whole;
        var ret = try (if (left.total_thickness > right.total_thickness) left else right).clone(st.a);
        const n = @min(left.bead_widths.len, right.bead_widths.len);
        for (0..n) |inset_idx| {
            if (left.bead_widths[inset_idx] == 0 or right.bead_widths[inset_idx] == 0) {
                // 0-width wall markers stay 0-width.
                ret.bead_widths[inset_idx] = 0;
            } else {
                ret.bead_widths[inset_idx] = beading_mod.trunc(ratio_left_to_whole * @as(f64, @floatFromInt(left.bead_widths[inset_idx])) + ratio_right_to_whole * @as(f64, @floatFromInt(right.bead_widths[inset_idx])));
            }
            ret.toolpath_locations[inset_idx] = beading_mod.trunc(ratio_left_to_whole * @as(f64, @floatFromInt(left.toolpath_locations[inset_idx])) + ratio_right_to_whole * @as(f64, @floatFromInt(right.toolpath_locations[inset_idx])));
        }
        return ret;
    }

    fn generateJunctions(st: *SkeletalTrapezoidation) !void {
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            // Only the upward half-edges.
            if (edge.from.distance_to_boundary > edge.to.distance_to_boundary) continue;
            const start_R = edge.to.distance_to_boundary; // higher R
            const end_R = edge.from.distance_to_boundary; // lower R
            // No beads.
            if ((edge.from.bead_count == edge.to.bead_count and edge.from.bead_count >= 0) or end_R >= start_R) continue;
            const beading = &(try st.getOrCreateBeading(edge.to)).beading;
            const ret = try st.a.create(LineJunctions);
            ret.* = .empty;
            edge.junctions = ret;
            const a_p = edge.to.p;
            const b_p = edge.from.p;
            const ab = b_p.sub(a_p);
            const num_junctions: i64 = @intCast(beading.toolpath_locations.len);
            // The first junction for this segment.
            var junction_idx: i64 = @divTrunc(@max(1, num_junctions) - 1, 2);
            while (junction_idx >= 0 and junction_idx < num_junctions) : (junction_idx -= 1) {
                const bead_R = beading.toolpath_locations[@intCast(junction_idx)];
                // +1 for a rounding error (a missing middle line).
                if (bead_R <= start_R + 1) break;
            }
            // Robustness against odd segments just outside the range by
            // rounding errors.
            if (junction_idx + 1 < num_junctions and beading.toolpath_locations[@intCast(junction_idx + 1)] <= start_R + 5 and beading.total_thickness < start_R + 5) junction_idx += 1;
            while (junction_idx >= 0 and junction_idx < num_junctions) : (junction_idx -= 1) {
                const k: usize = @intCast(junction_idx);
                const bead_R = beading.toolpath_locations[k];
                // A junction at a node belongs to the next segment.
                if (bead_R < end_R) break;
                var junction = a_p.add(divP(mulP(ab, bead_R - start_R), end_R - start_R));
                // Snap to the start node if it is very close, to see the
                // 3-way crossings later.
                if (bead_R > start_R - 5) junction = a_p;
                try ret.append(st.a, .{ .p = junction, .w = beading.bead_widths[k], .perimeter_index = @intCast(k) });
            }
        }
    }

    fn getOrCreateBeading(st: *SkeletalTrapezoidation, node: *Node) !*BeadingPropagation {
        if (node.beading) |b| return b;
        if (node.bead_count == -1) {
            // From too small central edges.
            const nearby_dist: i64 = 100;
            if (try st.getNearestBeading(node, nearby_dist)) |nb| return nb;
            // Else make a new beading.
            var dist: i64 = std.math.maxInt(i64);
            if (node.incident_edge) |first| {
                var edge = first;
                while (true) {
                    dist = @min(dist, edge.to.distance_to_boundary + vSize(edge.to.p.sub(edge.from.p)));
                    edge = edge.twin.?.next orelse break;
                    if (edge == first) break;
                }
            }
            if (dist == std.math.maxInt(i64)) dist = node.distance_to_boundary;
            node.bead_count = st.strategy.getOptimalBeadCount(dist * 2);
        }
        const bp = try st.a.create(BeadingPropagation);
        bp.* = .{ .beading = try st.strategy.compute(st.a, node.distance_to_boundary * 2, node.bead_count) };
        node.beading = bp;
        return bp;
    }

    fn getNearestBeading(st: *SkeletalTrapezoidation, node: *Node, max_dist: i64) !?*BeadingPropagation {
        const DistEdge = struct { edge_to: *Edge, dist: i64 };
        const Cmp = struct {
            fn order(_: void, l: DistEdge, r: DistEdge) std.math.Order {
                return std.math.order(l.dist, r.dist);
            }
        };
        var further: std.PriorityQueue(DistEdge, void, Cmp.order) = .empty;
        if (node.incident_edge) |first| {
            var outgoing = first;
            while (true) {
                try further.push(st.a, .{ .edge_to = outgoing, .dist = vSize(outgoing.to.p.sub(outgoing.from.p)) });
                outgoing = outgoing.twin.?.next orelse break;
                if (outgoing == first) break;
            }
        }
        for (0..bead_search_max) |_| {
            const here = further.pop() orelse return null;
            if (here.dist > max_dist) return null;
            if (here.edge_to.to.beading) |b| return b;
            var fe = here.edge_to.next;
            while (fe) |further_edge| : (fe = further_edge.twin.?.next) {
                if (further_edge == here.edge_to.twin) break;
                try further.push(st.a, .{ .edge_to = further_edge, .dist = here.dist + vSize(further_edge.to.p.sub(further_edge.from.p)) });
            }
        }
        return null;
    }

    fn addToolpathSegment(st: *SkeletalTrapezoidation, from: Junction, to: Junction, is_odd: bool, force_new_path_in: bool, from_is_3way: bool, to_is_3way: bool) !void {
        if (from.eql(to)) return;
        const a = st.a;
        var force_new_path = force_new_path_in;
        const inset_idx: usize = from.perimeter_index;
        while (inset_idx >= st.out.items.len) try st.out.append(a, .empty);
        const lines = &st.out.items[inset_idx];
        if (lines.items.len == 0 or lines.items[lines.items.len - 1].is_odd != is_odd or lines.items[lines.items.len - 1].junctions.items[lines.items[lines.items.len - 1].junctions.items.len - 1].perimeter_index != inset_idx) {
            force_new_path = true;
        }
        if (!force_new_path) {
            const last_line = &lines.items[lines.items.len - 1];
            const back = last_line.junctions.items[last_line.junctions.items.len - 1];
            if (shorterThan(back.p.sub(from.p), 10) and @abs(back.w - from.w) < 10 and !from_is_3way) {
                try last_line.junctions.append(a, to);
                return;
            }
            // CuraEngine notes: a reversed even wall line prints the wrong
            // way around.
            if (shorterThan(back.p.sub(to.p), 10) and @abs(back.w - to.w) < 10 and !to_is_3way) {
                try last_line.junctions.append(a, from);
                return;
            }
        }
        var line: Line = .{ .inset_idx = @intCast(inset_idx), .is_odd = is_odd };
        try line.junctions.append(a, from);
        try line.junctions.append(a, to);
        try lines.append(a, line);
    }

    fn connectJunctions(st: *SkeletalTrapezoidation) !void {
        const a = st.a;
        var quad_starts: std.ArrayList(*Edge) = .empty;
        for (st.edges.items) |edge| {
            if (edge.dead) continue;
            edge.quad_done = false;
            edge.passed_odd = false;
            if (edge.prev == null) try quad_starts.append(a, edge);
        }
        const empty_junctions: LineJunctions = .empty;
        var from_junctions: LineJunctions = .empty;
        var to_junctions: LineJunctions = .empty;
        for (quad_starts.items) |poly_domain_start| {
            if (poly_domain_start.quad_done) continue;
            var quad_start: *Edge = poly_domain_start;
            var new_domain_start = true;
            while (true) {
                var quad_end = quad_start;
                while (quad_end.next) |n| quad_end = n;
                const edge_to_peak = getQuadMaxRedgeTo(quad_start);
                // Walk down on both sides and connect the junctions.
                const edge_from_peak = edge_to_peak.next.?;
                quad_start.quad_done = true;
                // The junctions from the start of the quad to the node with
                // the highest R.
                from_junctions.clearRetainingCapacity();
                try from_junctions.appendSlice(a, (edge_to_peak.junctions orelse &empty_junctions).items);
                // The junctions from the end of the quad to that node.
                to_junctions.clearRetainingCapacity();
                try to_junctions.appendSlice(a, (edge_from_peak.twin.?.junctions orelse &empty_junctions).items);
                if (edge_to_peak.prev) |prev| {
                    const from_prev_junctions = (prev.junctions orelse &empty_junctions).items;
                    while (from_junctions.items.len > 0 and from_prev_junctions.len > 0 and from_junctions.items[from_junctions.items.len - 1].perimeter_index <= from_prev_junctions[0].perimeter_index) {
                        _ = from_junctions.pop();
                    }
                    try from_junctions.appendSlice(a, from_prev_junctions);
                }
                if (edge_from_peak.next) |next| {
                    const to_next_junctions = (next.twin.?.junctions orelse &empty_junctions).items;
                    while (to_junctions.items.len > 0 and to_next_junctions.len > 0 and to_junctions.items[to_junctions.items.len - 1].perimeter_index <= to_next_junctions[0].perimeter_index) {
                        _ = to_junctions.pop();
                    }
                    try to_junctions.appendSlice(a, to_next_junctions);
                }
                const fj = from_junctions.items;
                const tj = to_junctions.items;
                const segment_count = @min(fj.len, tj.len);
                for (0..segment_count) |junction_rev_idx| {
                    const from = fj[fj.len - 1 - junction_rev_idx];
                    const to = tj[tj.len - 1 - junction_rev_idx];
                    const qs = quad_start.to;
                    const qe = quad_end.from;
                    // The quad has a single bead segment, out of a
                    // transition.
                    const from_is_odd = qs.bead_count > 0 and @mod(qs.bead_count, 2) == 1 and qs.transition_ratio == 0 and junction_rev_idx == segment_count - 1 and shorterThan(from.p.sub(qs.p), 5);
                    const to_is_odd = qe.bead_count > 0 and @mod(qe.bead_count, 2) == 1 and qe.transition_ratio == 0 and junction_rev_idx == segment_count - 1 and shorterThan(to.p.sub(qe.p), 5);
                    const is_odd_segment = from_is_odd and to_is_odd;
                    // Make each single bead segment once.
                    if (is_odd_segment and quad_start.next.?.twin.?.passed_odd) continue;
                    const from_is_3way = from_is_odd and qs.isMultiIntersection();
                    const to_is_3way = to_is_odd and qe.isMultiIntersection();
                    quad_start.next.?.passed_odd = true;
                    try st.addToolpathSegment(from, to, is_odd_segment, new_domain_start, from_is_3way, to_is_3way);
                }
                new_domain_start = false;
                quad_start = quad_start.getNextUnconnected() orelse break;
                // Back at the start of the domain; or, in a broken graph (a
                // degenerate shape), at a quad that is done already.
                if (quad_start == poly_domain_start or quad_start.quad_done) break;
            }
        }
    }

    fn generateLocalMaximaSingleBeads(st: *SkeletalTrapezoidation) !void {
        const a = st.a;
        const LocalMaximaPoint = struct {
            p: Point,
            width: i64,
            accumulator: i64 = 1,
        };
        var local_maxima_points: std.ArrayList(LocalMaximaPoint) = .empty;
        for (st.nodes.items) |node| {
            if (node.dead) continue;
            const bp = node.beading orelse continue;
            const beading = bp.beading;
            if (beading.bead_widths.len % 2 == 1 and node.isLocalMaximum(true)) {
                const inset_index = beading.bead_widths.len / 2;
                const width = beading.bead_widths[inset_index];
                if (!node.isCentral()) {
                    try st.addCircleToToolpath(node.p, width, inset_index);
                } else {
                    // A line wider than it is long is removed later. In
                    // place of it, a small circle fills the gap.
                    const max_local_maxima_dist = @divTrunc(st.strategy.getOptimalWidth() * 3, 2);
                    const max2 = max_local_maxima_dist * max_local_maxima_dist;
                    var found = false;
                    for (local_maxima_points.items) |*lm| {
                        if (vSize2(lm.p.sub(node.p)) < max2) {
                            lm.p = lm.p.add(node.p);
                            lm.width += width;
                            lm.accumulator += 1;
                            found = true;
                            break;
                        }
                    }
                    if (!found) try local_maxima_points.append(a, .{ .p = node.p, .width = width });
                }
            }
        }
        var replace_with_local_maxima = st.out.items.len == 0 or st.out.items[0].items.len == 0;
        if (!replace_with_local_maxima) {
            var total_path_length: i64 = 0;
            var min_width: i64 = std.math.maxInt(i64);
            for (st.out.items[0].items) |line| {
                total_path_length += line.length();
                for (line.junctions.items) |j| min_width = @min(min_width, j.w);
            }
            replace_with_local_maxima = total_path_length <= @divTrunc(min_width, 2);
        }
        if (replace_with_local_maxima) {
            if (st.out.items.len == 0) {
                try st.out.append(a, .empty);
            } else {
                st.out.items[0].clearRetainingCapacity();
            }
            for (local_maxima_points.items) |lm| {
                const avg: Point = .{ .x = @divTrunc(lm.p.x, lm.accumulator), .y = @divTrunc(lm.p.y, lm.accumulator) };
                try st.addCircleToToolpath(avg, @divTrunc(lm.width, lm.accumulator), 0);
            }
        }
    }

    /// A small closed circle of 6 segments: the area of a dot of width w is
    /// pi w^2 / 4. A line of width w with that area is pi w / 4 long, the
    /// circumference of a circle of radius w / 8.
    fn addCircleToToolpath(st: *SkeletalTrapezoidation, center: Point, width: i64, inset_index: usize) !void {
        const a = st.a;
        while (inset_index >= st.out.items.len) try st.out.append(a, .empty);
        var line: Line = .{ .inset_idx = @intCast(inset_index), .is_odd = true };
        const r: f64 = @floatFromInt(@divTrunc(width, 8));
        const n_segments = 6;
        const step_angle = std.math.pi * 2.0 / @as(f64, n_segments);
        for (0..n_segments) |step| {
            const angle = @as(f64, @floatFromInt(step)) * step_angle;
            const q: Point = .{ .x = center.x + @as(i64, @intFromFloat(@round(r * @cos(angle)))), .y = center.y + @as(i64, @intFromFloat(@round(r * @sin(angle)))) };
            try line.junctions.append(a, .{ .p = q, .w = width, .perimeter_index = @intCast(inset_index) });
        }
        // Explicitly closed.
        try line.junctions.append(a, line.junctions.items[0]);
        try st.out.items[inset_index].append(a, line);
    }
};

/// The points along the parabola between the point p and the segment s,
/// from `start` to `end` (CuraEngine `voronoi_utils::discretizeParabola`).
/// Extra points: the apex, and the "markings" where the parabola gets
/// steeper than the transition angle.
fn discretizeParabola(a: Allocator, p: Point, segment: Segment, s: Point, e: Point, approximate_step_size: i64, transitioning_angle: f64) ![]Point {
    var discretized: std.ArrayList(Point) = .empty;
    // x is the distance of a point projected on the segment ab.
    const sa = segment.from;
    const sb = segment.to;
    const ab = sb.sub(sa);
    const as_ = s.sub(sa);
    const ae = e.sub(sa);
    const ab_size = vSize(ab);
    const sx = @divTrunc(dot(as_, ab), ab_size);
    const ex = @divTrunc(dot(ae, ab), ab_size);
    const sxex = ex - sx;
    const ap = p.sub(sa);
    const px = @divTrunc(dot(ap, ab), ab_size);
    const pxx = closestOnLine(p, sa, sb);
    const ppxx = pxx.sub(p);
    const d = vSize(ppxx);
    if (d == 0) {
        try discretized.append(a, s);
        try discretized.append(a, e);
        return discretized.items;
    }
    const rot = PointMatrix.init(turn90CCW(ppxx));
    const marking_bound = std.math.atan(transitioning_angle * 0.5);
    const df: f64 = @floatFromInt(d);
    var msx: i64 = beading_mod.trunc(-marking_bound * df); // the projected marking start
    var mex: i64 = beading_mod.trunc(marking_bound * df); // the projected marking end
    const marking_start_end_h = @divTrunc(msx * msx, 2 * d) + @divTrunc(d, 2);
    var marking_start = rot.unapply(.{ .x = msx, .y = marking_start_end_h }).add(pxx);
    var marking_end = rot.unapply(.{ .x = mex, .y = marking_start_end_h }).add(pxx);
    const dir: i64 = if (sx > ex) -1 else 1;
    if (dir < 0) {
        std.mem.swap(Point, &marking_start, &marking_end);
        std.mem.swap(i64, &msx, &mex);
    }
    var add_marking_start = msx * dir > (sx - px) * dir and msx * dir < (ex - px) * dir;
    var add_marking_end = mex * dir > (sx - px) * dir and mex * dir < (ex - px) * dir;
    const apex = rot.unapply(.{ .x = 0, .y = @divTrunc(d, 2) }).add(pxx);
    // The apex only if the projected start and end are more than 10
    // micrometers from it.
    var add_apex = (sx - px) * dir < -10 and (ex - px) * dir > 10;
    const step_count: i64 = @intFromFloat(@as(f64, @floatFromInt(@abs(ex - sx))) / @as(f64, @floatFromInt(approximate_step_size)) + 0.5);
    try discretized.append(a, s);
    var step: i64 = 1;
    while (step < step_count) : (step += 1) {
        const x = sx + @divTrunc(sxex * step, step_count) - px;
        const y = @divTrunc(x * x, 2 * d) + @divTrunc(d, 2);
        if (add_marking_start and msx * dir < x * dir) {
            try discretized.append(a, marking_start);
            add_marking_start = false;
        }
        if (add_apex and x * dir > 0) {
            try discretized.append(a, apex);
            add_apex = false;
        }
        if (add_marking_end and mex * dir < x * dir) {
            try discretized.append(a, marking_end);
            add_marking_end = false;
        }
        try discretized.append(a, rot.unapply(.{ .x = x, .y = y }).add(pxx));
    }
    if (add_apex) try discretized.append(a, apex);
    if (add_marking_end) try discretized.append(a, marking_end);
    try discretized.append(a, e);
    return discretized.items;
}

/// A rotation (CuraEngine `PointMatrix` from a direction).
const PointMatrix = struct {
    m: [4]f64,

    fn init(p: Point) PointMatrix {
        var m0: f64 = @floatFromInt(p.x);
        var m1: f64 = @floatFromInt(p.y);
        const f = @sqrt(m0 * m0 + m1 * m1);
        m0 /= f;
        m1 /= f;
        return .{ .m = .{ m0, m1, -m1, m0 } };
    }

    fn unapply(pm: PointMatrix, p: Point) Point {
        const x: f64 = @floatFromInt(p.x);
        const y: f64 = @floatFromInt(p.y);
        return .{ .x = @intFromFloat(@round(x * pm.m[0] + y * pm.m[2])), .y = @intFromFloat(@round(x * pm.m[1] + y * pm.m[3])) };
    }
};

fn dot(p: Point, q: Point) i64 {
    return p.x * q.x + p.y * q.y;
}

fn turn90CCW(p: Point) Point {
    return .{ .x = -p.y, .y = p.x };
}

fn mulP(p: Point, k: i64) Point {
    return .{ .x = p.x * k, .y = p.y * k };
}

fn divP(p: Point, k: i64) Point {
    return .{ .x = @divTrunc(p.x, k), .y = @divTrunc(p.y, k) };
}

/// The vector in the direction of p with the given length.
fn normal(p: Point, length: i64) Point {
    const len = vSize(p);
    if (len < 1) return .{ .x = length, .y = 0 };
    return divP(mulP(p, length), len);
}

/// True if the vector is not longer than `len`.
fn shorterThan(p: Point, len: i64) bool {
    if (p.x > len or p.x < -len) return false;
    if (p.y > len or p.y < -len) return false;
    return vSize2(p) <= len * len;
}

/// The point on the line through p0 and p1 closest to `from` (CuraEngine
/// `LinearAlg2D::getClosestOnLine`, with its integer steps).
fn closestOnLine(from: Point, p0: Point, p1: Point) Point {
    if (p1.eql(p0)) return p0;
    const direction = p1.sub(p0);
    const to_from = from.sub(p0);
    const projected_x = dot(to_from, direction);
    const len = vSize(direction);
    return p0.add(divP(mulP(direction, @divTrunc(projected_x, len)), len));
}

/// The point on the segment from p0 to p1 closest to `from`.
fn closestOnLineSegment(from: Point, p0: Point, p1: Point) Point {
    const direction = p1.sub(p0);
    const to_from = from.sub(p0);
    const projected_x = dot(to_from, direction);
    const x_p1 = vSize2(direction);
    // A segment of length 0.
    if (x_p1 == 0) return p0;
    if (projected_x <= 0) return p0;
    if (projected_x >= x_p1) return p1;
    const px: i128 = projected_x;
    return p0.add(.{ .x = @intCast(@divTrunc(px * direction.x, x_p1)), .y = @intCast(@divTrunc(px * direction.y, x_p1)) });
}
