//! Voronoi diagram of points and segments (sweep line method).
//!
//! The Voronoi diagram splits the plane into cells. Each cell holds the
//! places that are nearer to one input site than to all other sites. A site
//! is a point or a segment. The Arachne wall generator uses the diagram of
//! the polygon edges: inside a polygon, the cell edges form the medial axis
//! and the lines from it to the polygon vertices.
//!
//! The method is Fortune's sweep line, extended to segments:
//!
//! 1. Each input point makes one site. Each segment makes three sites: its
//!    two end points and the segment itself. The builder sorts the sites
//!    along x, and removes duplicates. So a vertex that two polygon edges
//!    share has one point cell.
//! 2. A vertical sweep line moves in +x. The "beach line" is the set of
//!    curves that are as far from the sweep line as from the nearest site
//!    left of it. Each node of the beach line is the bisector of two
//!    neighbor arcs. The nodes are in a balanced search tree (a treap),
//!    ordered by y along the sweep line.
//! 3. A site event inserts a new arc in the beach line, and starts two new
//!    half edges. A segment site also inserts a temporary node, which the
//!    event of its end point removes.
//! 4. Three neighbor arcs can meet at one point: the center of a circle
//!    that touches their three sites. When the sweep line gets to the right
//!    end of this circle, the middle arc vanishes. This is a circle event.
//!    It makes a Voronoi vertex and a new bisector. A priority queue holds
//!    the circle events, ordered by the right end x of the circle.
//! 5. At the end, the builder removes edges of zero length (their two
//!    vertices are within 128 ULPs), removes vertices with no edges, and
//!    links the infinite edges of each open cell.
//!
//! The predicates (`src/voronoi_predicates.zig`) decide the order of
//! events and of the beach line nodes. They use doubles with error bounds,
//! and big integers when the bounds are too large. So the topology of the
//! diagram is correct for all integer inputs that fit in 32 bits. The
//! input segments must not cross, except at their end points.
//!
//! The output is a half-edge structure. The two half edges of one edge are
//! at the indices 2k and 2k + 1, so the twin of edge e is e ^ 1. The
//! `next` edge of a half edge is the next edge of the same cell, in the
//! counterclockwise direction.
//!
//! This file is a port to Zig of boost::polygon voronoi
//! (https://github.com/boostorg/polygon, commit
//! ddb9c8adadbbb539fe52cb7f8ee0a446ba5ead04): `voronoi_builder.hpp`,
//! `voronoi_diagram.hpp`, `voronoi_geometry_type.hpp`, and
//! `detail/voronoi_structures.hpp`. The predicates and number types are in
//! `src/voronoi_predicates.zig` and `src/voronoi_ctypes.zig`. The changes:
//!
//! - Flat arrays with indices instead of pointers, and a treap instead of
//!   std::map. A new beach line node goes just before the hint node, as
//!   boost intends with its hint inserts.
//! - The circle event queue repeats the sift steps of the GNU C++ library
//!   heap. So events with equal keys come out in the same order as in boost
//!   built with GCC, and the diagram is the same.
//! - Of two equal input sites (a polygon vertex is the end of one segment
//!   and the start of the next), the first in the input order makes the
//!   cell. In boost, the order of std::sort decides. Only the
//!   `source_index` and `source_category` of such a point cell can differ.
//!
//! A test program in C++ with the boost headers gave the same cells,
//! vertices (bit for bit), and edges for random points, random polygons,
//! and 200000 segments of circles.
//!
//! Copyright Andrii Sydorchuk 2010-2012.
//! Distributed under the Boost Software License, Version 1.0. See
//! licenses/boost-BSL-1.0.txt and REFERENCES.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const pred = @import("voronoi_predicates.zig");
const ct = @import("voronoi_ctypes.zig");

const Site = pred.Site;
const Pt = pred.Pt;
const Key = pred.Key;
const CircleEvent = pred.Circle;

const nil: u32 = std.math.maxInt(u32);

pub const SourceCategory = enum(u8) {
    single_point,
    segment_start_point,
    segment_end_point,
    initial_segment,
    reverse_segment,

    fn fromFlags(c: u8) SourceCategory {
        return switch (c) {
            pred.cat_single_point => .single_point,
            pred.cat_segment_start_point => .segment_start_point,
            pred.cat_segment_end_point => .segment_end_point,
            pred.cat_initial_segment => .initial_segment,
            else => .reverse_segment,
        };
    }
};

pub const Cell = struct {
    /// The index of the input site: points first, then segments.
    source_index: u32,
    source_category: SourceCategory,
    /// One half edge of the cell, or null for a cell with no edges.
    incident_edge: ?u32 = null,

    pub fn containsPoint(c: Cell) bool {
        return switch (c.source_category) {
            .single_point, .segment_start_point, .segment_end_point => true,
            else => false,
        };
    }

    pub fn containsSegment(c: Cell) bool {
        return !c.containsPoint();
    }
};

pub const Vertex = struct {
    x: f64,
    y: f64,
    incident_edge: u32,
};

pub const Edge = struct {
    cell: u32,
    /// The start vertex, or null when the edge starts at infinity.
    vertex0: ?u32,
    /// The next edge of the same cell, counterclockwise.
    next: u32,
    prev: u32,
    /// The edge is a line or a ray (false: a parabolic arc).
    is_linear: bool,
    /// False for the edge between a segment and its own end point.
    is_primary: bool,

    pub fn isSecondary(e: Edge) bool {
        return !e.is_primary;
    }
};

pub const Diagram = struct {
    cells: []Cell,
    vertices: []Vertex,
    edges: []Edge,

    pub fn twin(e: u32) u32 {
        return e ^ 1;
    }

    pub fn vertex1(d: *const Diagram, e: u32) ?u32 {
        return d.edges[e ^ 1].vertex0;
    }

    /// The next edge around the start vertex, counterclockwise.
    pub fn rotNext(d: *const Diagram, e: u32) u32 {
        return d.edges[e].prev ^ 1;
    }

    /// The previous edge around the start vertex.
    pub fn rotPrev(d: *const Diagram, e: u32) u32 {
        return d.edges[e ^ 1].next;
    }

    pub fn isFinite(d: *const Diagram, e: u32) bool {
        return d.edges[e].vertex0 != null and d.vertex1(e) != null;
    }

    pub fn isInfinite(d: *const Diagram, e: u32) bool {
        return !d.isFinite(e);
    }

    pub fn deinit(d: *Diagram, gpa: Allocator) void {
        gpa.free(d.cells);
        gpa.free(d.vertices);
        gpa.free(d.edges);
        d.* = undefined;
    }
};

/// Builds the Voronoi diagram of the points and segments. The coordinates
/// must fit in i32. A segment is [start, end]. Its sites have the
/// categories segment_start_point and segment_end_point. The segments must
/// not cross, except at their end points.
pub fn build(gpa: Allocator, points: []const geom.Point, segments: []const [2]geom.Point) !Diagram {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    try b.sites.ensureTotalCapacity(gpa, points.len + 3 * segments.len);
    var index: u32 = 0;
    for (points) |p| {
        const q = toPt(p);
        b.sites.appendAssumeCapacity(.{ .p0 = q, .p1 = q, .initial_index = index, .flags = pred.cat_single_point });
        index += 1;
    }
    for (segments) |s| {
        const p1 = toPt(s[0]);
        const p2 = toPt(s[1]);
        b.sites.appendAssumeCapacity(.{ .p0 = p1, .p1 = p1, .initial_index = index, .flags = pred.cat_segment_start_point });
        b.sites.appendAssumeCapacity(.{ .p0 = p2, .p1 = p2, .initial_index = index, .flags = pred.cat_segment_end_point });
        if (p1.less(p2)) {
            b.sites.appendAssumeCapacity(.{ .p0 = p1, .p1 = p2, .initial_index = index, .flags = pred.cat_initial_segment });
        } else {
            b.sites.appendAssumeCapacity(.{ .p0 = p2, .p1 = p1, .initial_index = index, .flags = pred.cat_reverse_segment });
        }
        index += 1;
    }
    try b.construct();
    return b.output();
}

fn toPt(p: geom.Point) Pt {
    return .{ .x = @intCast(p.x), .y = @intCast(p.y) };
}

// ---------------------------------------------------------------------------
// Builder state.

const BNode = struct {
    key: Key,
    edge: u32,
    circle: u32 = nil,
    l: u32 = nil,
    r: u32 = nil,
    parent: u32 = nil,
    prio: u32,
};

const CircleSlot = struct {
    c: CircleEvent,
    node: u32,
    active: bool,
};

const EndPoint = struct {
    pt: Pt,
    node: u32,
};

const BEdge = struct {
    cell: u32,
    vertex0: u32 = nil,
    next: u32 = nil,
    prev: u32 = nil,
    is_linear: bool,
    is_primary: bool,
};

const BVertex = struct {
    x: f64,
    y: f64,
    incident_edge: u32 = nil,
};

const BCell = struct {
    source_index: u32,
    category: u8,
    incident_edge: u32 = nil,
};

const Builder = struct {
    gpa: Allocator,
    sites: std.ArrayList(Site) = .empty,
    site_it: usize = 0,

    // Beach line (treap).
    nodes: std.ArrayList(BNode) = .empty,
    free_nodes: std.ArrayList(u32) = .empty,
    root: u32 = nil,
    rng: u32 = 0x9E3779B9,

    // Circle events.
    circles: std.ArrayList(CircleSlot) = .empty,
    free_circles: std.ArrayList(u32) = .empty,
    heap: std.ArrayList(u32) = .empty,

    // Temporary nodes of segments, keyed by their end point.
    end_points: std.ArrayList(EndPoint) = .empty,

    // Output.
    cells: std.ArrayList(BCell) = .empty,
    vertices: std.ArrayList(BVertex) = .empty,
    edges: std.ArrayList(BEdge) = .empty,

    fn deinit(b: *Builder) void {
        const gpa = b.gpa;
        b.sites.deinit(gpa);
        b.nodes.deinit(gpa);
        b.free_nodes.deinit(gpa);
        b.circles.deinit(gpa);
        b.free_circles.deinit(gpa);
        b.heap.deinit(gpa);
        b.end_points.deinit(gpa);
        b.cells.deinit(gpa);
        b.vertices.deinit(gpa);
        b.edges.deinit(gpa);
    }

    // -- treap ---------------------------------------------------------------

    fn nextPrio(b: *Builder) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    fn node(b: *Builder, n: u32) *BNode {
        return &b.nodes.items[n];
    }

    fn first(b: *Builder) u32 {
        var n = b.root;
        if (n == nil) return nil;
        while (b.node(n).l != nil) n = b.node(n).l;
        return n;
    }

    fn last(b: *Builder) u32 {
        var n = b.root;
        if (n == nil) return nil;
        while (b.node(n).r != nil) n = b.node(n).r;
        return n;
    }

    fn succ(b: *Builder, n_in: u32) u32 {
        var n = n_in;
        if (b.node(n).r != nil) {
            n = b.node(n).r;
            while (b.node(n).l != nil) n = b.node(n).l;
            return n;
        }
        var p = b.node(n).parent;
        while (p != nil and b.node(p).r == n) {
            n = p;
            p = b.node(p).parent;
        }
        return p;
    }

    /// The node before `n`. For `n` == nil (the end), the last node.
    fn pred_(b: *Builder, n_in: u32) u32 {
        if (n_in == nil) return b.last();
        var n = n_in;
        if (b.node(n).l != nil) {
            n = b.node(n).l;
            while (b.node(n).r != nil) n = b.node(n).r;
            return n;
        }
        var p = b.node(n).parent;
        while (p != nil and b.node(p).l == n) {
            n = p;
            p = b.node(p).parent;
        }
        return p;
    }

    /// The first node that is not less than the key (std::map::lower_bound).
    fn lowerBound(b: *Builder, key: *const Key) u32 {
        var x = b.root;
        var y: u32 = nil;
        while (x != nil) {
            if (!pred.nodeLess(&b.node(x).key, key)) {
                y = x;
                x = b.node(x).l;
            } else {
                x = b.node(x).r;
            }
        }
        return y;
    }

    fn setChild(b: *Builder, parent: u32, old: u32, new: u32) void {
        if (parent == nil) {
            b.root = new;
        } else if (b.node(parent).l == old) {
            b.node(parent).l = new;
        } else {
            b.node(parent).r = new;
        }
        if (new != nil) b.node(new).parent = parent;
    }

    /// Rotates `x` up over its parent.
    fn rotateUp(b: *Builder, x: u32) void {
        const p = b.node(x).parent;
        const g = b.node(p).parent;
        if (b.node(p).l == x) {
            const mid = b.node(x).r;
            b.node(p).l = mid;
            if (mid != nil) b.node(mid).parent = p;
            b.node(x).r = p;
        } else {
            const mid = b.node(x).l;
            b.node(p).r = mid;
            if (mid != nil) b.node(mid).parent = p;
            b.node(x).l = p;
        }
        b.node(p).parent = x;
        b.setChild(g, p, x);
    }

    /// Inserts a new node just before `pos` (or at the end for nil). The
    /// caller knows that this is the right place in the order.
    fn insertBefore(b: *Builder, pos: u32, key: Key, edge: u32) !u32 {
        const n: u32 = if (b.free_nodes.pop()) |f| f else blk: {
            try b.nodes.append(b.gpa, undefined);
            break :blk @intCast(b.nodes.items.len - 1);
        };
        b.nodes.items[n] = .{ .key = key, .edge = edge, .prio = b.nextPrio() };
        if (b.root == nil) {
            b.root = n;
            return n;
        }
        if (pos == nil) {
            const m = b.last();
            b.node(m).r = n;
            b.node(n).parent = m;
        } else if (b.node(pos).l == nil) {
            b.node(pos).l = n;
            b.node(n).parent = pos;
        } else {
            var m = b.node(pos).l;
            while (b.node(m).r != nil) m = b.node(m).r;
            b.node(m).r = n;
            b.node(n).parent = m;
        }
        while (b.node(n).parent != nil and b.node(b.node(n).parent).prio < b.node(n).prio) {
            b.rotateUp(n);
        }
        return n;
    }

    fn erase(b: *Builder, n: u32) !void {
        // Rotate the node down until it is a leaf.
        while (true) {
            const l = b.node(n).l;
            const r = b.node(n).r;
            if (l == nil and r == nil) break;
            if (l == nil) {
                b.rotateUp(r);
            } else if (r == nil) {
                b.rotateUp(l);
            } else if (b.node(l).prio > b.node(r).prio) {
                b.rotateUp(l);
            } else {
                b.rotateUp(r);
            }
        }
        b.setChild(b.node(n).parent, n, nil);
        try b.free_nodes.append(b.gpa, n);
    }

    // -- circle event queue ------------------------------------------------
    //
    // A binary heap with the sift steps of the C++ standard library
    // (libstdc++ push_heap and pop_heap). Circle events with equal keys are
    // common for cocircular input. The same steps give the same order of
    // these events as boost, and so the same diagram.

    /// The heap order: `a` is below `b` when `b` is the earlier event.
    fn heapComp(b: *Builder, x: u32, y: u32) bool {
        return pred.circleLess(&b.circles.items[y].c, &b.circles.items[x].c);
    }

    fn siftUp(b: *Builder, hole_in: usize, top: usize, value: u32) void {
        const h = b.heap.items;
        var hole = hole_in;
        var parent = if (hole > 0) (hole - 1) / 2 else 0;
        while (hole > top and b.heapComp(h[parent], value)) {
            h[hole] = h[parent];
            hole = parent;
            parent = if (hole > 0) (hole - 1) / 2 else 0;
        }
        h[hole] = value;
    }

    fn pushCircle(b: *Builder, c: CircleEvent, n: u32) !u32 {
        const slot: u32 = if (b.free_circles.pop()) |f| f else blk: {
            try b.circles.append(b.gpa, undefined);
            break :blk @intCast(b.circles.items.len - 1);
        };
        b.circles.items[slot] = .{ .c = c, .node = n, .active = true };
        try b.heap.append(b.gpa, slot);
        b.siftUp(b.heap.items.len - 1, 0, slot);
        return slot;
    }

    fn topCircle(b: *Builder) u32 {
        return b.heap.items[0];
    }

    fn popCircle(b: *Builder) !void {
        const h = b.heap.items;
        const top = h[0];
        const total = h.len;
        if (total > 1) {
            // pop_heap: move the last value out, sift the hole from the top
            // down to a leaf, then sift the value up from there.
            const len = total - 1;
            const value = h[len];
            h[len] = h[0];
            var hole: usize = 0;
            var second: usize = 0;
            while (len > 0 and second < (len - 1) / 2) {
                second = 2 * (second + 1);
                if (b.heapComp(h[second], h[second - 1])) second -= 1;
                h[hole] = h[second];
                hole = second;
            }
            if (len & 1 == 0 and second == (len -% 2) / 2) {
                second = 2 * (second + 1);
                h[hole] = h[second - 1];
                hole = second - 1;
            }
            b.siftUp(hole, 0, value);
        }
        b.heap.items.len -= 1;
        try b.free_circles.append(b.gpa, top);
    }

    // -- end point queue (min by point) ------------------------------------

    fn epLess(a: EndPoint, c: EndPoint) bool {
        return a.pt.less(c.pt);
    }

    fn pushEndPoint(b: *Builder, e: EndPoint) !void {
        try b.end_points.append(b.gpa, e);
        const h = b.end_points.items;
        var i = h.len - 1;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (!epLess(h[i], h[p])) break;
            std.mem.swap(EndPoint, &h[i], &h[p]);
            i = p;
        }
    }

    fn popEndPoint(b: *Builder) void {
        const h = b.end_points.items;
        const last_v = h[h.len - 1];
        b.end_points.items.len -= 1;
        const n = b.end_points.items.len;
        if (n == 0) return;
        const hh = b.end_points.items;
        hh[0] = last_v;
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            if (l >= n) break;
            var m = l;
            if (l + 1 < n and epLess(hh[l + 1], hh[l])) m = l + 1;
            if (!epLess(hh[m], hh[i])) break;
            std.mem.swap(EndPoint, &hh[i], &hh[m]);
            i = m;
        }
    }

    // -- output --------------------------------------------------------------

    fn isPrimaryEdge(s1: *const Site, s2: *const Site) bool {
        const flag1 = s1.isSegment();
        const flag2 = s2.isSegment();
        if (flag1 and !flag2) return !s1.p0.eql(s2.p0) and !s1.p1.eql(s2.p0);
        if (!flag1 and flag2) return !s2.p0.eql(s1.p0) and !s2.p1.eql(s1.p0);
        return true;
    }

    fn isLinearEdge(s1: *const Site, s2: *const Site) bool {
        if (!isPrimaryEdge(s1, s2)) return true;
        return s1.isSegment() == s2.isSegment();
    }

    fn pushCell(b: *Builder, s: *const Site) !void {
        try b.cells.append(b.gpa, .{ .source_index = s.initial_index, .category = s.category() });
    }

    /// A new bisector of two sites. Returns the first of the two half edges.
    fn insertNewEdge(b: *Builder, s1: *const Site, s2: *const Site) !u32 {
        const lin = isLinearEdge(s1, s2);
        const prim = isPrimaryEdge(s1, s2);
        const e1: u32 = @intCast(b.edges.items.len);
        try b.edges.append(b.gpa, .{ .cell = s1.sorted_index, .is_linear = lin, .is_primary = prim });
        try b.edges.append(b.gpa, .{ .cell = s2.sorted_index, .is_linear = lin, .is_primary = prim });
        if (b.cells.items.len == 0) try b.pushCell(s1);
        try b.pushCell(s2);
        return e1;
    }

    /// A new bisector that starts at the vertex of a circle event, where the
    /// bisectors e12 and e23 meet.
    fn insertNewEdgeCircle(b: *Builder, s1: *const Site, s3: *const Site, c: *const CircleEvent, e12: u32, e23: u32) !u32 {
        const v: u32 = @intCast(b.vertices.items.len);
        try b.vertices.append(b.gpa, .{ .x = c.x, .y = c.y });
        const E = b.edges.items;
        E[e12].vertex0 = v;
        E[e23].vertex0 = v;
        const lin = isLinearEdge(s1, s3);
        const prim = isPrimaryEdge(s1, s3);
        const ne1: u32 = @intCast(b.edges.items.len);
        const ne2 = ne1 + 1;
        try b.edges.append(b.gpa, .{ .cell = s1.sorted_index, .is_linear = lin, .is_primary = prim });
        try b.edges.append(b.gpa, .{ .cell = s3.sorted_index, .is_linear = lin, .is_primary = prim, .vertex0 = v });
        const e = b.edges.items;
        e[e12].prev = ne1;
        e[ne1].next = e12;
        e[e12 ^ 1].next = e23;
        e[e23].prev = e12 ^ 1;
        e[e23 ^ 1].next = ne2;
        e[ne2].prev = e23 ^ 1;
        return ne1;
    }

    // -- sweep -------------------------------------------------------------

    fn construct(b: *Builder) !void {
        const gpa = b.gpa;
        // Sort the sites and remove duplicates. Sites that compare equal keep
        // their input order, so that the result is deterministic.
        const Ctx = struct {
            fn lt(_: void, a: Site, c: Site) bool {
                if (pred.siteLess(&a, &c)) return true;
                if (pred.siteLess(&c, &a)) return false;
                if (a.initial_index != c.initial_index) return a.initial_index < c.initial_index;
                return a.category() < c.category();
            }
        };
        std.mem.sortUnstable(Site, b.sites.items, {}, Ctx.lt);
        {
            const s = b.sites.items;
            var w: usize = 0;
            for (s, 0..) |site, i| {
                if (i > 0 and site.eql(&s[w - 1])) continue;
                s[w] = site;
                w += 1;
            }
            b.sites.items.len = w;
        }
        for (b.sites.items, 0..) |*s, i| s.sorted_index = @intCast(i);

        const n = b.sites.items.len;
        try b.cells.ensureTotalCapacity(gpa, n);
        try b.vertices.ensureTotalCapacity(gpa, n * 2);
        try b.edges.ensureTotalCapacity(gpa, n * 6);
        try b.nodes.ensureTotalCapacity(gpa, 64);

        try b.initBeachLine();

        while (b.heap.items.len != 0 or b.site_it < n) {
            if (b.heap.items.len == 0) {
                try b.processSiteEvent();
            } else if (b.site_it == n) {
                try b.processCircleEvent();
            } else {
                if (pred.siteLessCircle(&b.sites.items[b.site_it], &b.circles.items[b.topCircle()].c)) {
                    try b.processSiteEvent();
                } else {
                    try b.processCircleEvent();
                }
            }
            while (b.heap.items.len != 0 and !b.circles.items[b.topCircle()].active) {
                try b.popCircle();
            }
        }
        try b.finish();
    }

    fn initBeachLine(b: *Builder) !void {
        const s = b.sites.items;
        if (s.len == 0) return;
        if (s.len == 1) {
            try b.pushCell(&s[0]);
            b.site_it += 1;
            return;
        }
        var skip: usize = 0;
        while (b.site_it < s.len and
            pred.isVerticalPts(s[b.site_it].p0, s[0].p0) and
            pred.isVertical(&s[b.site_it]))
        {
            b.site_it += 1;
            skip += 1;
        }
        if (skip == 1) {
            // Init the beach line with the first two sites.
            const s0 = s[0];
            _ = try b.insertNewArc(&s0, &s0, &s[1], nil);
            b.site_it += 1;
        } else {
            // Init the beach line with collinear vertical sites.
            var i: usize = 0;
            while (i + 1 < b.site_it) : (i += 1) {
                const key: Key = .{ .left = s[i], .right = s[i + 1] };
                const e = try b.insertNewEdge(&s[i], &s[i + 1]);
                _ = try b.insertBefore(nil, key, e);
            }
        }
    }

    fn deactivateCircleEvent(b: *Builder, n: u32) void {
        const c = b.node(n).circle;
        if (c != nil) {
            b.circles.items[c].active = false;
            b.node(n).circle = nil;
        }
    }

    fn processSiteEvent(b: *Builder) !void {
        const sites = b.sites.items;
        var site_event = sites[b.site_it];
        var last_it = b.site_it + 1;

        if (!site_event.isSegment()) {
            // Remove the temporary nodes of the segments that end here.
            while (b.end_points.items.len != 0 and b.end_points.items[0].pt.eql(site_event.p0)) {
                const bn = b.end_points.items[0].node;
                b.popEndPoint();
                // Boost leaves a circle event of the node in the queue. Such
                // an event never comes up in a valid run. The deactivation
                // makes sure that no event points to a free node.
                b.deactivateCircleEvent(bn);
                try b.erase(bn);
            }
        } else {
            while (last_it < sites.len and sites[last_it].isSegment() and sites[last_it].p0.eql(site_event.p0)) {
                last_it += 1;
            }
        }

        // The node with the left arc above the new site.
        const new_key: Key = .{ .left = sites[b.site_it], .right = sites[b.site_it] };
        var right_it = b.lowerBound(&new_key);
        while (b.site_it != last_it) : (b.site_it += 1) {
            site_event = sites[b.site_it];
            var left_it = right_it;
            if (right_it == nil) {
                // The arc is the second arc of the last node.
                left_it = b.pred_(left_it);
                const site_arc = b.node(left_it).key.right;
                right_it = try b.insertNewArc(&site_arc, &site_arc, &site_event, right_it);
                const k = b.node(left_it).key;
                try b.activateCircleEvent(&k.left, &k.right, &site_event, right_it);
            } else if (right_it == b.first()) {
                // The arc is the first arc of the first node.
                const site_arc = b.node(right_it).key.left;
                left_it = try b.insertNewArc(&site_arc, &site_arc, &site_event, right_it);
                if (site_event.isSegment()) site_event.inverse();
                const k = b.node(right_it).key;
                try b.activateCircleEvent(&site_event, &k.left, &k.right, right_it);
                right_it = left_it;
            } else {
                const site_arc2 = b.node(right_it).key.left;
                const site3 = b.node(right_it).key.right;
                b.deactivateCircleEvent(right_it);
                left_it = b.pred_(left_it);
                const site_arc1 = b.node(left_it).key.right;
                const site1 = b.node(left_it).key.left;
                const new_node_it = try b.insertNewArc(&site_arc1, &site_arc2, &site_event, right_it);
                try b.activateCircleEvent(&site1, &site_arc1, &site_event, new_node_it);
                if (site_event.isSegment()) site_event.inverse();
                try b.activateCircleEvent(&site_event, &site_arc2, &site3, right_it);
                right_it = new_node_it;
            }
        }
    }

    fn processCircleEvent(b: *Builder) !void {
        const slot = b.topCircle();
        const circle_event = b.circles.items[slot].c;
        var it_first = b.circles.items[slot].node;
        var it_last = it_first;

        var site3 = b.node(it_first).key.right;
        const bisector2 = b.node(it_first).edge;
        it_first = b.pred_(it_first);
        const bisector1 = b.node(it_first).edge;
        const site1 = b.node(it_first).key.left;

        if (!site1.isSegment() and site3.isSegment() and site3.p1.eql(site1.p0)) {
            site3.inverse();
        }

        // Change the (A, B) bisector node to the (A, C) bisector node.
        b.node(it_first).key.right = site3;
        b.node(it_first).edge = try b.insertNewEdgeCircle(&site1, &site3, &circle_event, bisector1, bisector2);

        // Remove the (B, C) bisector node.
        try b.erase(it_last);
        it_last = it_first;

        try b.popCircle();

        if (it_first != b.first()) {
            b.deactivateCircleEvent(it_first);
            it_first = b.pred_(it_first);
            const site_l1 = b.node(it_first).key.left;
            try b.activateCircleEvent(&site_l1, &site1, &site3, it_last);
        }

        it_last = b.succ(it_last);
        if (it_last != nil) {
            b.deactivateCircleEvent(it_last);
            const site_r1 = b.node(it_last).key.right;
            try b.activateCircleEvent(&site1, &site3, &site_r1, it_last);
        }
    }

    fn insertNewArc(b: *Builder, site_arc1: *const Site, site_arc2: *const Site, site_event: *const Site, position_in: u32) !u32 {
        var position = position_in;
        const new_left: Key = .{ .left = site_arc1.*, .right = site_event.* };
        var new_right: Key = .{ .left = site_event.*, .right = site_arc2.* };
        if (site_event.isSegment()) new_right.left.inverse();

        const e1 = try b.insertNewEdge(site_arc2, site_event);
        position = try b.insertBefore(position, new_right, e1 + 1);

        if (site_event.isSegment()) {
            var temp: Key = .{ .left = site_event.*, .right = site_event.* };
            temp.right.inverse();
            position = try b.insertBefore(position, temp, nil);
            try b.pushEndPoint(.{ .pt = site_event.p1, .node = position });
        }

        position = try b.insertBefore(position, new_left, e1);
        return position;
    }

    fn activateCircleEvent(b: *Builder, s1: *const Site, s2: *const Site, s3: *const Site, bisector_node: u32) !void {
        var c: CircleEvent = .{};
        if (pred.circleFormation(s1, s2, s3, &c)) {
            const slot = try b.pushCircle(c, bisector_node);
            b.node(bisector_node).circle = slot;
        }
    }

    // -- final cleanup (voronoi_diagram::_build) ----------------------------

    fn vertexEqual(v1: *const BVertex, v2: *const BVertex) bool {
        return ct.ulpCmp(v1.x, v2.x, 128) == .equal and ct.ulpCmp(v1.y, v2.y, 128) == .equal;
    }

    fn rotNextB(e: []BEdge, i: u32) u32 {
        return e[i].prev ^ 1;
    }

    fn rotPrevB(e: []BEdge, i: u32) u32 {
        return e[i ^ 1].next;
    }

    fn removeEdge(b: *Builder, edge: u32) void {
        const e = b.edges.items;
        const vertex = e[edge].vertex0;
        var updated = rotNextB(e, edge ^ 1);
        while (updated != (edge ^ 1)) {
            e[updated].vertex0 = vertex;
            updated = rotNextB(e, updated);
        }
        const edge1 = edge;
        const edge2 = edge ^ 1;
        const edge1_rot_prev = rotPrevB(e, edge1);
        const edge1_rot_next = rotNextB(e, edge1);
        const edge2_rot_prev = rotPrevB(e, edge2);
        const edge2_rot_next = rotNextB(e, edge2);
        e[edge1_rot_next ^ 1].next = edge2_rot_prev;
        e[edge2_rot_prev].prev = edge1_rot_next ^ 1;
        e[edge1_rot_prev].prev = edge2_rot_next ^ 1;
        e[edge2_rot_next ^ 1].next = edge1_rot_prev;
    }

    fn finish(b: *Builder) !void {
        // Remove degenerate edges.
        {
            var last_edge: u32 = 0;
            var it: u32 = 0;
            const count: u32 = @intCast(b.edges.items.len);
            while (it < count) : (it += 2) {
                const e = b.edges.items;
                const v1 = e[it].vertex0;
                const v2 = e[it + 1].vertex0;
                if (v1 != nil and v2 != nil and vertexEqual(&b.vertices.items[v1], &b.vertices.items[v2])) {
                    b.removeEdge(it);
                } else {
                    if (it != last_edge) {
                        e[last_edge] = e[it];
                        e[last_edge + 1] = e[it + 1];
                        const e1 = last_edge;
                        const e2 = last_edge + 1;
                        if (e[e1].prev != nil) {
                            e[e[e1].prev].next = e1;
                            e[e[e2].next].prev = e2;
                        }
                        if (e[e2].prev != nil) {
                            e[e[e1].next].prev = e1;
                            e[e[e2].prev].next = e2;
                        }
                    }
                    last_edge += 2;
                }
            }
            b.edges.items.len = last_edge;
        }

        // Set up the incident edges of the cells and the vertices.
        for (b.edges.items, 0..) |*e, i| {
            b.cells.items[e.cell].incident_edge = @intCast(i);
            if (e.vertex0 != nil) b.vertices.items[e.vertex0].incident_edge = @intCast(i);
        }

        // Remove degenerate vertices.
        {
            var last_vertex: u32 = 0;
            const V = b.vertices.items;
            const E = b.edges.items;
            for (0..V.len) |it| {
                if (V[it].incident_edge != nil) {
                    if (it != last_vertex) {
                        V[last_vertex] = V[it];
                        const start = V[last_vertex].incident_edge;
                        var e = start;
                        while (true) {
                            E[e].vertex0 = last_vertex;
                            e = rotNextB(E, e);
                            if (e == start) break;
                        }
                    }
                    last_vertex += 1;
                }
            }
            b.vertices.items.len = last_vertex;
        }

        // Set up the next and prev links of the infinite edges.
        const E = b.edges.items;
        if (b.vertices.items.len == 0) {
            if (E.len != 0) {
                // The edges are parallel lines.
                var idx: usize = 0;
                var edge1: u32 = @intCast(idx);
                E[edge1].next = edge1;
                E[edge1].prev = edge1;
                idx += 1;
                edge1 = @intCast(idx);
                idx += 1;
                while (idx < E.len) {
                    const edge2: u32 = @intCast(idx);
                    idx += 1;
                    E[edge1].next = edge2;
                    E[edge1].prev = edge2;
                    E[edge2].next = edge1;
                    E[edge2].prev = edge1;
                    edge1 = @intCast(idx);
                    idx += 1;
                }
                E[edge1].next = edge1;
                E[edge1].prev = edge1;
            }
        } else {
            for (b.cells.items) |*cell| {
                if (cell.incident_edge == nil) continue;
                var left_edge = cell.incident_edge;
                while (E[left_edge].prev != nil) {
                    left_edge = E[left_edge].prev;
                    if (left_edge == cell.incident_edge) break;
                }
                if (E[left_edge].prev != nil) continue;
                var right_edge = cell.incident_edge;
                while (E[right_edge].next != nil) right_edge = E[right_edge].next;
                E[left_edge].prev = right_edge;
                E[right_edge].next = left_edge;
            }
        }
    }

    fn output(b: *Builder) !Diagram {
        const gpa = b.gpa;
        const cells = try gpa.alloc(Cell, b.cells.items.len);
        errdefer gpa.free(cells);
        const vertices = try gpa.alloc(Vertex, b.vertices.items.len);
        errdefer gpa.free(vertices);
        const edges = try gpa.alloc(Edge, b.edges.items.len);
        for (b.cells.items, cells) |s, *d| {
            d.* = .{
                .source_index = s.source_index,
                .source_category = SourceCategory.fromFlags(s.category),
                .incident_edge = if (s.incident_edge == nil) null else s.incident_edge,
            };
        }
        for (b.vertices.items, vertices) |s, *d| {
            d.* = .{ .x = s.x, .y = s.y, .incident_edge = s.incident_edge };
        }
        for (b.edges.items, edges) |s, *d| {
            d.* = .{
                .cell = s.cell,
                .vertex0 = if (s.vertex0 == nil) null else s.vertex0,
                .next = s.next,
                .prev = s.prev,
                .is_linear = s.is_linear,
                .is_primary = s.is_primary,
            };
        }
        return .{ .cells = cells, .vertices = vertices, .edges = edges };
    }
};

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

const TestSite = union(enum) {
    point: [2]f64,
    segment: [2][2]f64,
};

/// The input site of a cell, as doubles.
fn cellSite(c: Cell, points: []const geom.Point, segments: []const [2]geom.Point) TestSite {
    const i = c.source_index;
    const np: u32 = @intCast(points.len);
    const P = struct {
        fn p(q: geom.Point) [2]f64 {
            return .{ @floatFromInt(q.x), @floatFromInt(q.y) };
        }
    };
    return switch (c.source_category) {
        .single_point => .{ .point = P.p(points[i]) },
        .segment_start_point => .{ .point = P.p(segments[i - np][0]) },
        .segment_end_point => .{ .point = P.p(segments[i - np][1]) },
        else => .{ .segment = .{ P.p(segments[i - np][0]), P.p(segments[i - np][1]) } },
    };
}

fn siteDist(s: TestSite, x: f64, y: f64) f64 {
    switch (s) {
        .point => |p| return @import("geom.zig").hypot(x - p[0], y - p[1]),
        .segment => |sg| {
            const ax = sg[0][0];
            const ay = sg[0][1];
            const dx = sg[1][0] - ax;
            const dy = sg[1][1] - ay;
            const l2 = dx * dx + dy * dy;
            var t = ((x - ax) * dx + (y - ay) * dy) / l2;
            t = std.math.clamp(t, 0.0, 1.0);
            return @import("geom.zig").hypot(x - (ax + t * dx), y - (ay + t * dy));
        },
    }
}

/// Checks the diagram against brute force. Returns an error on a fault.
fn checkDiagram(d: *const Diagram, points: []const geom.Point, segments: []const [2]geom.Point, rng: std.Random) !void {
    const E = d.edges;
    try testing.expect(E.len % 2 == 0);
    // Half-edge structure.
    for (E, 0..) |e, i_| {
        const i: u32 = @intCast(i_);
        try testing.expectEqual(i, Diagram.twin(Diagram.twin(i)));
        try testing.expectEqual(i, E[e.next].prev);
        try testing.expectEqual(i, E[e.prev].next);
        try testing.expectEqual(e.cell, E[e.next].cell);
        // The end of this edge is the start of the next edge.
        if (d.vertex1(i)) |v1| {
            if (E[e.next].vertex0) |v0n| try testing.expectEqual(v1, v0n);
        }
    }
    // Each input site has one cell. Shared end points give one cell.
    {
        var seen = std.AutoHashMap([3]i64, void).init(testing.allocator);
        defer seen.deinit();
        for (d.cells) |c| {
            const key: [3]i64 = switch (cellSite(c, points, segments)) {
                .point => |p| .{ @intFromFloat(p[0]), @intFromFloat(p[1]), -1 },
                .segment => .{ c.source_index, 0, -2 },
            };
            const gop = try seen.getOrPut(key);
            try testing.expect(!gop.found_existing);
        }
        for (points) |p| try testing.expect(seen.contains(.{ p.x, p.y, -1 }));
        for (segments, 0..) |s, i| {
            try testing.expect(seen.contains(.{ s[0].x, s[0].y, -1 }));
            try testing.expect(seen.contains(.{ s[1].x, s[1].y, -1 }));
            try testing.expect(seen.contains(.{ @intCast(points.len + i), 0, -2 }));
        }
    }
    // Each Voronoi vertex is equally far from the sites of the cells around
    // it, and no other site is nearer.
    var all_sites: std.ArrayList(TestSite) = .empty;
    defer all_sites.deinit(testing.allocator);
    for (d.cells) |c| try all_sites.append(testing.allocator, cellSite(c, points, segments));
    for (d.vertices, 0..) |v, vi| {
        const start = v.incident_edge;
        var e = start;
        var dmin: f64 = std.math.inf(f64);
        var dmax: f64 = 0;
        var n: usize = 0;
        while (true) {
            try testing.expectEqual(@as(?u32, @intCast(vi)), E[e].vertex0);
            const s = all_sites.items[E[e].cell];
            const dd = siteDist(s, v.x, v.y);
            dmin = @min(dmin, dd);
            dmax = @max(dmax, dd);
            e = d.rotNext(e);
            n += 1;
            if (e == start) break;
            try testing.expect(n < 10000);
        }
        const tol = 1e-6 * @max(1.0, dmax) + 1e-6;
        try testing.expect(dmax - dmin <= tol);
        for (all_sites.items) |s| {
            try testing.expect(siteDist(s, v.x, v.y) >= dmin - tol);
        }
    }
    // A sample point on each finite edge is nearest to the sites of the two
    // cells of the edge.
    var k: usize = 0;
    while (k < @min(E.len, 200)) : (k += 1) {
        const i: u32 = @intCast(rng.uintLessThan(usize, E.len));
        if (!d.isFinite(i)) continue;
        if (!E[i].is_linear) continue;
        const a = d.vertices[E[i].vertex0.?];
        const c = d.vertices[d.vertex1(i).?];
        const t = rng.float(f64);
        const x = a.x + t * (c.x - a.x);
        const y = a.y + t * (c.y - a.y);
        const d1 = siteDist(all_sites.items[E[i].cell], x, y);
        const d2 = siteDist(all_sites.items[E[i ^ 1].cell], x, y);
        const tol = 1e-6 * @max(1.0, d1) + 1e-6;
        try testing.expect(@abs(d1 - d2) <= tol);
        for (all_sites.items) |s| try testing.expect(siteDist(s, x, y) >= d1 - tol);
    }
}

fn runCheck(points: []const geom.Point, segments: []const [2]geom.Point, seed: u64) !void {
    var d = try build(testing.allocator, points, segments);
    defer d.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(seed);
    try checkDiagram(&d, points, segments, prng.random());
}

fn polygonSegments(gpa: Allocator, list: *std.ArrayList([2]geom.Point), poly: []const geom.Point) !void {
    for (poly, 0..) |p, i| {
        try list.append(gpa, .{ p, poly[(i + 1) % poly.len] });
    }
}

test "random points against brute force" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    for (0..30) |round| {
        var pts: std.ArrayList(geom.Point) = .empty;
        defer pts.deinit(testing.allocator);
        var seen = std.AutoHashMap([2]i64, void).init(testing.allocator);
        defer seen.deinit();
        const n = 2 + r.uintLessThan(usize, 120);
        const span: i64 = if (round % 3 == 0) 20 else 100000;
        while (pts.items.len < n) {
            const p = geom.Point.init(r.intRangeAtMost(i64, -span, span), r.intRangeAtMost(i64, -span, span));
            if ((try seen.getOrPut(.{ p.x, p.y })).found_existing) continue;
            try pts.append(testing.allocator, p);
        }
        try runCheck(pts.items, &.{}, round);
    }
}

test "degenerate points: collinear and cocircular" {
    var pts: std.ArrayList(geom.Point) = .empty;
    defer pts.deinit(testing.allocator);
    // Collinear on a horizontal, a vertical, and a diagonal line.
    for (0..10) |i| try pts.append(testing.allocator, geom.Point.init(@intCast(i * 100), 0));
    try runCheck(pts.items, &.{}, 2);
    pts.clearRetainingCapacity();
    for (0..10) |i| try pts.append(testing.allocator, geom.Point.init(0, @intCast(i * 100)));
    try runCheck(pts.items, &.{}, 3);
    pts.clearRetainingCapacity();
    for (0..10) |i| try pts.append(testing.allocator, geom.Point.init(@intCast(i * 70), @intCast(i * 70)));
    try runCheck(pts.items, &.{}, 4);
    // A square grid: many cocircular points.
    pts.clearRetainingCapacity();
    for (0..12) |i| for (0..12) |j| try pts.append(testing.allocator, geom.Point.init(@intCast(i * 1000), @intCast(j * 1000)));
    try runCheck(pts.items, &.{}, 5);
    // Points on a circle.
    pts.clearRetainingCapacity();
    for ([_][2]i64{ .{ 5, 0 }, .{ 4, 3 }, .{ 3, 4 }, .{ 0, 5 }, .{ -3, 4 }, .{ -4, 3 }, .{ -5, 0 }, .{ -4, -3 }, .{ -3, -4 }, .{ 0, -5 }, .{ 3, -4 }, .{ 4, -3 } }) |q| {
        try pts.append(testing.allocator, geom.Point.init(q[0] * 1000, q[1] * 1000));
    }
    try runCheck(pts.items, &.{}, 6);
}

test "square with a square hole" {
    var segs: std.ArrayList([2]geom.Point) = .empty;
    defer segs.deinit(testing.allocator);
    const P = geom.Point.init;
    try polygonSegments(testing.allocator, &segs, &.{ P(0, 0), P(10000, 0), P(10000, 10000), P(0, 10000) });
    try polygonSegments(testing.allocator, &segs, &.{ P(3000, 3000), P(3000, 7000), P(7000, 7000), P(7000, 3000) });
    try runCheck(&.{}, segs.items, 7);

    var d = try build(testing.allocator, &.{}, segs.items);
    defer d.deinit(testing.allocator);
    // 8 segment cells and 8 point cells.
    try testing.expectEqual(@as(usize, 16), d.cells.len);
}

test "concave polygons and collinear edges" {
    var segs: std.ArrayList([2]geom.Point) = .empty;
    defer segs.deinit(testing.allocator);
    const P = geom.Point.init;
    // An L shape with collinear consecutive edges, and a comb.
    try polygonSegments(testing.allocator, &segs, &.{ P(0, 0), P(5000, 0), P(10000, 0), P(10000, 3000), P(3000, 3000), P(3000, 10000), P(0, 10000), P(0, 5000) });
    try runCheck(&.{}, segs.items, 8);
    segs.clearRetainingCapacity();
    var comb: std.ArrayList(geom.Point) = .empty;
    defer comb.deinit(testing.allocator);
    try comb.append(testing.allocator, P(0, 0));
    try comb.append(testing.allocator, P(8000, 0));
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        const x: i64 = @intCast(i * 1000);
        try comb.append(testing.allocator, P(x + 1000, 5000));
        try comb.append(testing.allocator, P(x + 700, 5000));
        try comb.append(testing.allocator, P(x + 700, 400));
        try comb.append(testing.allocator, P(x + 300, 400));
        try comb.append(testing.allocator, P(x + 300, 5000));
    }
    try comb.append(testing.allocator, P(0, 5000));
    try polygonSegments(testing.allocator, &segs, comb.items);
    try runCheck(&.{}, segs.items, 9);
}

/// A random star shaped polygon: simple, often concave. The polygon keeps
/// only the vertices that turn counterclockwise around the center after the
/// rounding to integers, so that no two edges cross.
fn randomStar(gpa: Allocator, r: std.Random, cx: i64, cy: i64, radius: f64, n: usize, out: *std.ArrayList(geom.Point)) !void {
    out.clearRetainingCapacity();
    var angles: std.ArrayList(f64) = .empty;
    defer angles.deinit(gpa);
    for (0..n) |_| try angles.append(gpa, r.float(f64) * 2 * std.math.pi);
    std.mem.sortUnstable(f64, angles.items, {}, std.sort.asc(f64));
    const c = geom.Point.init(cx, cy);
    for (angles.items) |a| {
        const rr = radius * (0.3 + 0.7 * r.float(f64));
        const p = geom.Point.init(cx + @as(i64, @intFromFloat(rr * @cos(a))), cy + @as(i64, @intFromFloat(rr * @sin(a))));
        if (p.eql(c)) continue;
        if (out.items.len > 0 and geom.cross3(c, out.items[out.items.len - 1], p) <= 0) continue;
        try out.append(gpa, p);
    }
    while (out.items.len > 2 and geom.cross3(c, out.items[out.items.len - 1], out.items[0]) <= 0) _ = out.pop();
    // The polygon must go around the center: no wedge of pi or more.
    if (out.items.len < 3) {
        out.clearRetainingCapacity();
        return;
    }
}

test "random star polygons against brute force" {
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    var poly: std.ArrayList(geom.Point) = .empty;
    defer poly.deinit(testing.allocator);
    var segs: std.ArrayList([2]geom.Point) = .empty;
    defer segs.deinit(testing.allocator);
    for (0..40) |round| {
        segs.clearRetainingCapacity();
        const radius: f64 = if (round % 4 == 0) 50 else 200000;
        const n = 3 + r.uintLessThan(usize, 60);
        try randomStar(testing.allocator, r, 0, 0, radius, n, &poly);
        if (poly.items.len < 3) continue;
        // Skip polygons with collinear angle duplicates that cross.
        try polygonSegments(testing.allocator, &segs, poly.items);
        try runCheck(&.{}, segs.items, round);
    }
}

test "random disjoint short segments on a grid" {
    var prng = std.Random.DefaultPrng.init(21);
    const r = prng.random();
    var segs: std.ArrayList([2]geom.Point) = .empty;
    defer segs.deinit(testing.allocator);
    for (0..30) |round| {
        segs.clearRetainingCapacity();
        // One segment in each grid cell, inside the cell, so none cross.
        const cell: i64 = if (round % 2 == 0) 1000 else 10;
        const g = 2 + r.uintLessThan(usize, 9);
        for (0..g) |i| for (0..g) |j| {
            if (r.boolean()) continue;
            const ox = @as(i64, @intCast(i)) * cell;
            const oy = @as(i64, @intCast(j)) * cell;
            const a = geom.Point.init(ox + r.intRangeLessThan(i64, 0, cell), oy + r.intRangeLessThan(i64, 0, cell));
            var c = geom.Point.init(ox + r.intRangeLessThan(i64, 0, cell), oy + r.intRangeLessThan(i64, 0, cell));
            if (c.eql(a)) c.x = if (a.x == ox) ox + 1 else ox;
            try segs.append(testing.allocator, .{ a, c });
        };
        // Some isolated points too, on cell corners.
        var pts: std.ArrayList(geom.Point) = .empty;
        defer pts.deinit(testing.allocator);
        if (round % 3 == 0) {
            try pts.append(testing.allocator, geom.Point.init(-cell, -cell));
            try pts.append(testing.allocator, geom.Point.init(-cell, 5 * cell));
        }
        if (segs.items.len == 0) continue;
        try runCheck(pts.items, segs.items, round);
    }
}

test "large coordinates" {
    var segs: std.ArrayList([2]geom.Point) = .empty;
    defer segs.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(31);
    const r = prng.random();
    var poly: std.ArrayList(geom.Point) = .empty;
    defer poly.deinit(testing.allocator);
    for (0..10) |round| {
        segs.clearRetainingCapacity();
        try randomStar(testing.allocator, r, 300000, -280000, 30000, 40, &poly);
        if (poly.items.len < 3) continue;
        try polygonSegments(testing.allocator, &segs, poly.items);
        // A hole near the center.
        const P = geom.Point.init;
        try polygonSegments(testing.allocator, &segs, &.{ P(299000, -281000), P(299000, -279000), P(301000, -279000), P(301000, -281000) });
        try runCheck(&.{}, segs.items, round);
    }
}

test "single site and two sites" {
    const P = geom.Point.init;
    var d = try build(testing.allocator, &.{P(5, 5)}, &.{});
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.cells.len);
    try testing.expectEqual(@as(usize, 0), d.edges.len);
    try runCheck(&.{ P(0, 0), P(10, 0) }, &.{}, 1);
    try runCheck(&.{}, &.{.{ P(0, 0), P(10, 7) }}, 1);
}

test "timing of a large polygon set" {
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(41);
    const r = prng.random();
    var segs: std.ArrayList([2]geom.Point) = .empty;
    defer segs.deinit(testing.allocator);
    var poly: std.ArrayList(geom.Point) = .empty;
    defer poly.deinit(testing.allocator);
    // 100 star polygons on a 10 x 10 grid, 1000 vertices each.
    for (0..10) |i| for (0..10) |j| {
        try randomStar(testing.allocator, r, @as(i64, @intCast(i)) * 30000, @as(i64, @intCast(j)) * 30000, 14000, 1000, &poly);
        try polygonSegments(testing.allocator, &segs, poly.items);
    };
    const io = testing.io;
    const t0 = std.Io.Clock.awake.now(io);
    var d = try build(testing.allocator, &.{}, segs.items);
    defer d.deinit(testing.allocator);
    const ns = t0.untilNow(io, .awake).toNanoseconds();
    std.debug.print("\nvoronoi: {d} segments, {d} cells, {d} vertices, {d} edges in {d:.1} ms\n", .{
        segs.items.len, d.cells.len, d.vertices.len, d.edges.len, @as(f64, @floatFromInt(ns)) / 1e6,
    });
}
