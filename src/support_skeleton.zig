//! The support skeleton: tree support as data.
//!
//! A tree is a set of nodes. Each node has a center (x, y), a layer, and a
//! radius, and points to the next node toward the bed (`down`). The part
//! of a branch between a node and its `down` node is a straight segment:
//! on each layer between them, the center and the radius go linearly from
//! one node to the other. A node with no `down` node is a root: a foot on
//! the bed (layer 0), or the end of a branch that rests on the part. A
//! node where branches join is the `down` node of each of them.
//!
//! The tree planner (tree_support.zig) writes the skeleton. support.zig
//! makes the area of each layer from it (`disks`). An editor can move a
//! node, change its radius, or add a branch, and the layers follow.
//!
//! A branch is made from the per-layer path of the planner: `addChain`
//! keeps only the nodes that the straight segments need. A node is kept
//! where the path bends, or where the radius changes its rate, by more
//! than a set tolerance (a split at the worst point, as in the method of
//! Douglas and Peucker; see REFERENCES.md).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const none = std.math.maxInt(u32);

pub const Node = struct {
    /// The center, µm.
    x: f64,
    y: f64,
    layer: u32,
    /// The radius, µm.
    r: f64,
    /// The next node toward the bed, or `none`.
    down: u32 = none,
    /// The top node of a branch, under the pad of an overhang.
    tip: bool = false,
};

/// A circle of a branch on one layer.
pub const Disk = struct { x: f64, y: f64, r: f64, fill: bool = false };

pub const Skeleton = struct {
    nodes: std.ArrayList(Node) = .empty,

    pub fn deinit(s: *Skeleton, gpa: Allocator) void {
        s.nodes.deinit(gpa);
    }

    /// The root of the tree of node i.
    pub fn root(s: *const Skeleton, i: u32) u32 {
        var k = i;
        while (s.nodes.items[k].down != none) k = s.nodes.items[k].down;
        return k;
    }

    /// Adds a branch from a path of one point a layer, from the top down:
    /// `pts[k]` is on layer `top - k`. Keeps the first and the last point,
    /// each point in `keep` (true: the point must stay), and the points
    /// that the segments need to stay within `tol` µm of the path (center
    /// and radius). Returns the index of the last node. Its `down` is
    /// `none`; the caller links it.
    pub fn addChain(s: *Skeleton, gpa: Allocator, top: u32, pts: []const Disk, keep: []const bool, tip: bool, tol: f64) Allocator.Error!u32 {
        std.debug.assert(pts.len > 0);
        var stack: std.ArrayList([2]usize) = .empty;
        defer stack.deinit(gpa);
        const mark = try gpa.alloc(bool, pts.len);
        defer gpa.free(mark);
        @memcpy(mark, keep);
        mark[0] = true;
        mark[pts.len - 1] = true;
        // Split each span at the kept points first, then at the worst point.
        var a: usize = 0;
        for (1..pts.len) |k| if (mark[k]) {
            try stack.append(gpa, .{ a, k });
            a = k;
        };
        while (stack.pop()) |span| {
            const lo = span[0];
            const hi = span[1];
            if (hi - lo < 2) continue;
            var worst: f64 = 0;
            var at: usize = 0;
            for (lo + 1..hi) |k| {
                const t = @as(f64, @floatFromInt(k - lo)) / @as(f64, @floatFromInt(hi - lo));
                const p = pts[lo];
                const q = pts[hi];
                const dx = pts[k].x - (p.x + (q.x - p.x) * t);
                const dy = pts[k].y - (p.y + (q.y - p.y) * t);
                const dr = @abs(pts[k].r - (p.r + (q.r - p.r) * t));
                const e = @max(@sqrt(dx * dx + dy * dy), dr);
                if (e > worst) {
                    worst = e;
                    at = k;
                }
            }
            if (worst <= tol) continue;
            mark[at] = true;
            try stack.append(gpa, .{ lo, at });
            try stack.append(gpa, .{ at, hi });
        }
        var last: u32 = none;
        for (pts, mark, 0..) |p, m, k| {
            if (!m) continue;
            const idx: u32 = @intCast(s.nodes.items.len);
            if (last != none) s.nodes.items[last].down = idx;
            try s.nodes.append(gpa, .{ .x = p.x, .y = p.y, .r = p.r, .layer = top - @as(u32, @intCast(k)), .tip = tip and k == 0 });
            last = idx;
        }
        return last;
    }

    /// The disks of each layer (`n` layers), in `a`. The disks of a
    /// segment go from the layer under its top node down to the layer
    /// over its `down` node; each node adds its own disk. `keep(root)`
    /// says if a tree stays (for example: only trees on the bed). A disk
    /// prints filled on the layers 1 to `fill_layers`, and within
    /// `fill_layers` under a tip.
    pub fn disks(s: *const Skeleton, a: Allocator, n: usize, fill_layers: u32, keep: ?[]const bool) Allocator.Error![]std.ArrayList(Disk) {
        return s.disksHead(a, n, fill_layers, keep, 0, 0);
    }

    /// `disks`, with a head on each tip: on the `head_layers` layers of a
    /// tip, the radius grows by `head_grow` µm a layer up to the top. So
    /// the pad over a tip stands on the tip, and the head under it leans
    /// at the angle of a branch.
    pub fn disksHead(s: *const Skeleton, a: Allocator, n: usize, fill_layers: u32, keep: ?[]const bool, head_layers: u32, head_grow: f64) Allocator.Error![]std.ArrayList(Disk) {
        const out = try a.alloc(std.ArrayList(Disk), n);
        for (out) |*o| o.* = .empty;
        const items = s.nodes.items;
        // The tip layer over each node of a branch, for the filled layers
        // under a tip: a node takes the top of the chain over it.
        const top = try a.alloc(u32, items.len);
        @memset(top, 0);
        for (items, 0..) |nd, i| if (nd.tip) {
            top[i] = nd.layer;
        };
        // From the top layer down, each node passes its top to its down
        // node (a join takes the highest top).
        const order = try a.alloc(u32, items.len);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, items, struct {
            fn lt(ns: []const Node, x: u32, y: u32) bool {
                return ns[x].layer > ns[y].layer or (ns[x].layer == ns[y].layer and x < y);
            }
        }.lt);
        for (order) |i| {
            const nd = items[i];
            if (nd.down != none and top[i] > 0) top[nd.down] = @max(top[nd.down], top[i]);
        }
        for (items, 0..) |nd, i| {
            if (keep) |kp| if (!kp[s.root(@intCast(i))]) continue;
            const fill = struct {
                fn f(j: u32, t: u32, fl: u32) bool {
                    return (j >= 1 and j <= fl) or (t > 0 and j + fl >= t and j <= t);
                }
            }.f;
            const head = struct {
                fn f(t: u32, j: u32, hl: u32, hg: f64) f64 {
                    if (t == 0 or j > t or t - j >= hl) return 0;
                    return @as(f64, @floatFromInt(hl - (t - j))) * hg;
                }
            }.f;
            try out[nd.layer].append(a, .{ .x = nd.x, .y = nd.y, .r = nd.r + head(top[i], nd.layer, head_layers, head_grow), .fill = fill(nd.layer, top[i], fill_layers) });
            if (nd.down == none) continue;
            const d = items[nd.down];
            const span: f64 = @floatFromInt(nd.layer - d.layer);
            var j = nd.layer - 1;
            while (j > d.layer) : (j -= 1) {
                const t = @as(f64, @floatFromInt(nd.layer - j)) / span;
                try out[j].append(a, .{
                    .x = nd.x + (d.x - nd.x) * t,
                    .y = nd.y + (d.y - nd.y) * t,
                    .r = nd.r + (d.r - nd.r) * t + head(top[i], j, head_layers, head_grow),
                    .fill = fill(j, top[i], fill_layers),
                });
            }
        }
        return out;
    }
};

const testing = std.testing;

test "a straight path keeps only its ends, and a bend keeps its corner" {
    const gpa = testing.allocator;
    var s: Skeleton = .{};
    defer s.deinit(gpa);
    var pts: [11]Disk = undefined;
    for (&pts, 0..) |*p, k| p.* = .{ .x = @floatFromInt(100 * k), .y = 0, .r = 500 + @as(f64, @floatFromInt(10 * k)) };
    const keep = [_]bool{false} ** 11;
    const last = try s.addChain(gpa, 20, &pts, &keep, true, 20);
    try testing.expectEqual(@as(usize, 2), s.nodes.items.len);
    try testing.expectEqual(@as(u32, 10), s.nodes.items[last].layer);
    // A bend at the middle: three nodes.
    for (pts[5..]) |*p| p.x = 500;
    var s2: Skeleton = .{};
    defer s2.deinit(gpa);
    _ = try s2.addChain(gpa, 20, &pts, &keep, true, 20);
    try testing.expectEqual(@as(usize, 3), s2.nodes.items.len);
    // The disks of the layers between the nodes follow the segments.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ds = try s2.disks(arena.allocator(), 21, 3, null);
    try testing.expectEqual(@as(usize, 1), ds[12].items.len);
    try testing.expectApproxEqAbs(@as(f64, 300), ds[17].items[0].x, 1e-6);
    try testing.expect(ds[20].items[0].fill and !ds[12].items[0].fill);
}
