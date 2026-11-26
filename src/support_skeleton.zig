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
//! Douglas and Peucker; see docs/references/papers-and-algorithms.md).
//!
//! The editor works on branches. A branch is a run of nodes between
//! joins: a node and its `down` node are on the same branch if no other
//! node joins at the `down` node. So a tip starts a branch, a join starts
//! the branch under it, and each node is on one branch. `Edit` keeps the
//! trees of the user for one part, as text in a project file.

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

    pub fn clone(s: *const Skeleton, gpa: Allocator) Allocator.Error!Skeleton {
        return .{ .nodes = try s.nodes.clone(gpa) };
    }

    /// Adds the nodes of `o`, moved by (dx, dy) µm.
    pub fn appendMoved(s: *Skeleton, gpa: Allocator, o: *const Skeleton, dx: f64, dy: f64) Allocator.Error!void {
        const base: u32 = @intCast(s.nodes.items.len);
        try s.nodes.ensureUnusedCapacity(gpa, o.nodes.items.len);
        for (o.nodes.items) |nd| {
            var c = nd;
            c.x += dx;
            c.y += dy;
            if (c.down != none) c.down += base;
            s.nodes.appendAssumeCapacity(c);
        }
    }

    /// A hash of the nodes. Never 0.
    pub fn hash(s: *const Skeleton) u64 {
        var h = std.hash.Wyhash.init(0x7ee5);
        for (s.nodes.items) |nd| h.update(std.mem.asBytes(&[_]f64{ nd.x, nd.y, nd.r, @floatFromInt(nd.layer), @floatFromInt(nd.down), @floatFromInt(@intFromBool(nd.tip)) }));
        return h.final() | 1;
    }

    /// The count of nodes whose `down` is each node, in `a`.
    pub fn kidCounts(s: *const Skeleton, a: Allocator) Allocator.Error![]u32 {
        const k = try a.alloc(u32, s.nodes.items.len);
        @memset(k, 0);
        for (s.nodes.items) |nd| if (nd.down != none) {
            k[nd.down] += 1;
        };
        return k;
    }

    /// The branch of each node (see the header), in `a`: the branches are
    /// 0, 1, 2, ... in the order of their top nodes.
    pub fn branches(s: *const Skeleton, a: Allocator) Allocator.Error![]u32 {
        const items = s.nodes.items;
        const kids = try kidCounts(s, a);
        defer a.free(kids);
        // The node above a node with one node above it.
        const only = try a.alloc(u32, items.len);
        defer a.free(only);
        @memset(only, none);
        for (items, 0..) |nd, i| if (nd.down != none and kids[nd.down] == 1) {
            only[nd.down] = @intCast(i);
        };
        // The top of the branch of each node: from the top layer down, a
        // node takes the top of the node above it.
        const top = try a.alloc(u32, items.len);
        defer a.free(top);
        const order = try a.alloc(u32, items.len);
        defer a.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, items, struct {
            fn lt(ns: []const Node, x: u32, y: u32) bool {
                return ns[x].layer > ns[y].layer or (ns[x].layer == ns[y].layer and x < y);
            }
        }.lt);
        for (order) |i| top[i] = if (only[i] != none and items[only[i]].layer > items[i].layer) top[only[i]] else i;
        const id = try a.alloc(u32, items.len);
        errdefer a.free(id);
        const of_top = try a.alloc(u32, items.len);
        defer a.free(of_top);
        @memset(of_top, none);
        var next: u32 = 0;
        for (0..items.len) |i| {
            const t = top[i];
            if (of_top[t] == none) {
                of_top[t] = next;
                next += 1;
            }
            id[i] = of_top[t];
        }
        return id;
    }

    /// The nodes of the branch of node i, from the top down, in `a`.
    pub fn branchOf(s: *const Skeleton, a: Allocator, i: u32) Allocator.Error![]u32 {
        const ids = try s.branches(a);
        defer a.free(ids);
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(a);
        for (ids, 0..) |b, k| if (b == ids[i]) try out.append(a, @intCast(k));
        std.mem.sort(u32, out.items, s.nodes.items, struct {
            fn lt(ns: []const Node, x: u32, y: u32) bool {
                return ns[x].layer > ns[y].layer;
            }
        }.lt);
        return out.toOwnedSlice(a);
    }

    /// Removes node i, its branch, and all nodes over them (the nodes whose
    /// way to the bed goes through the branch). Returns the count of nodes
    /// that went.
    pub fn removeBranch(s: *Skeleton, a: Allocator, i: u32) Allocator.Error!usize {
        const items = s.nodes.items;
        const gone = try a.alloc(bool, items.len);
        defer a.free(gone);
        @memset(gone, false);
        const br = try s.branchOf(a, i);
        defer a.free(br);
        for (br) |k| gone[k] = true;
        // A node goes if its down node goes: from the bottom layer up, so
        // each down node is known first.
        const order = try a.alloc(u32, items.len);
        defer a.free(order);
        for (order, 0..) |*o, k| o.* = @intCast(k);
        std.mem.sort(u32, order, items, struct {
            fn lt(ns: []const Node, x: u32, y: u32) bool {
                return ns[x].layer < ns[y].layer or (ns[x].layer == ns[y].layer and x < y);
            }
        }.lt);
        for (order) |k| {
            const d = items[k].down;
            if (d != none and gone[d]) gone[k] = true;
        }
        return s.removeNodes(a, gone);
    }

    /// Removes the nodes with `gone[i]`. A node whose down node goes
    /// becomes a root. Returns the count of nodes that went.
    pub fn removeNodes(s: *Skeleton, a: Allocator, gone: []const bool) Allocator.Error!usize {
        const items = s.nodes.items;
        const new_of = try a.alloc(u32, items.len);
        defer a.free(new_of);
        var n: u32 = 0;
        for (gone, new_of) |g, *x| {
            x.* = if (g) none else n;
            if (!g) n += 1;
        }
        var k: usize = 0;
        for (items, 0..) |nd, i| {
            if (gone[i]) continue;
            var c = nd;
            if (c.down != none) c.down = new_of[c.down];
            items[k] = c;
            k += 1;
        }
        const removed = items.len - k;
        s.nodes.items.len = k;
        return removed;
    }

    /// The layer of the highest tip over each node, in `a` (0 under no
    /// tip).
    pub fn topTips(s: *const Skeleton, a: Allocator) Allocator.Error![]u32 {
        const items = s.nodes.items;
        const top = try a.alloc(u32, items.len);
        errdefer a.free(top);
        for (items, top) |nd, *t| t.* = if (nd.tip) nd.layer else 0;
        const order = try a.alloc(u32, items.len);
        defer a.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, items, struct {
            fn lt(ns: []const Node, x: u32, y: u32) bool {
                return ns[x].layer > ns[y].layer or (ns[x].layer == ns[y].layer and x < y);
            }
        }.lt);
        for (order) |i| {
            const d = items[i].down;
            if (d != none) top[d] = @max(top[d], top[i]);
        }
        return top;
    }

    /// True if each node is on a layer under `n`, has a radius, and each
    /// `down` is a node on a lower layer. False for a skeleton from a bad
    /// file.
    pub fn valid(s: *const Skeleton, n: usize) bool {
        for (s.nodes.items) |nd| {
            if (nd.layer >= n or !std.math.isFinite(nd.x) or !std.math.isFinite(nd.y) or !(nd.r > 0)) return false;
            if (nd.down != none and (nd.down >= s.nodes.items.len or s.nodes.items[nd.down].layer >= nd.layer)) return false;
        }
        return true;
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

/// The trees of the user for one part (the support editor). The slice
/// uses them in place of the plan (see support.Trees). The nodes are in
/// µm from the center of the footprint of the part, so the trees move
/// with the part. A turn or a scale of the part changes its shape, and a
/// change of the layers changes the meaning of the layer of a node: then
/// the trees no longer fit, and the app drops them.
pub const Edit = struct {
    sk: Skeleton = .{},
    /// The shape of the part when the trees were made (see plate.Part.shape).
    shape: [7]f64,
    /// The key of the layers of the slice (see engine.layersKey).
    layers: u64,

    pub fn deinit(e: *Edit, gpa: Allocator) void {
        e.sk.deinit(gpa);
    }

    pub fn clone(e: *const Edit, gpa: Allocator) Allocator.Error!Edit {
        return .{ .sk = try e.sk.clone(gpa), .shape = e.shape, .layers = e.layers };
    }

    /// The text of the trees in a project file, after a tag and the part:
    /// "layers key <tab> shape <tab> x,y,layer,r,down,tip;...". The
    /// numbers round-trip exactly.
    pub fn write(e: *const Edit, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{x}\t", .{e.layers});
        for (e.shape, 0..) |v, k| try w.print("{s}{d}", .{ if (k == 0) "" else ",", v });
        try w.writeByte('\t');
        for (e.sk.nodes.items, 0..) |nd, k| {
            const down: i64 = if (nd.down == none) -1 else nd.down;
            try w.print("{s}{d},{d},{d},{d},{d},{d}", .{ if (k == 0) "" else ";", nd.x, nd.y, nd.layer, nd.r, down, @intFromBool(nd.tip) });
        }
    }

    /// Reads the text of `write`. Null for a bad text.
    pub fn read(gpa: Allocator, text: []const u8) Allocator.Error!?Edit {
        var f = std.mem.splitScalar(u8, text, '\t');
        const layers = std.fmt.parseInt(u64, f.next() orelse return null, 16) catch return null;
        var shape: [7]f64 = undefined;
        var sv = std.mem.splitScalar(u8, f.next() orelse return null, ',');
        for (&shape) |*v| v.* = std.fmt.parseFloat(f64, sv.next() orelse return null) catch return null;
        var e: Edit = .{ .shape = shape, .layers = layers };
        errdefer e.deinit(gpa);
        const body = f.next() orelse return null;
        var it = std.mem.tokenizeScalar(u8, body, ';');
        while (it.next()) |t| {
            var c = std.mem.splitScalar(u8, t, ',');
            const x = std.fmt.parseFloat(f64, c.next() orelse return bad(gpa, &e)) catch return bad(gpa, &e);
            const y = std.fmt.parseFloat(f64, c.next() orelse return bad(gpa, &e)) catch return bad(gpa, &e);
            const layer = std.fmt.parseInt(u32, c.next() orelse return bad(gpa, &e), 10) catch return bad(gpa, &e);
            const r = std.fmt.parseFloat(f64, c.next() orelse return bad(gpa, &e)) catch return bad(gpa, &e);
            const down = std.fmt.parseInt(i64, c.next() orelse return bad(gpa, &e), 10) catch return bad(gpa, &e);
            const tip = std.fmt.parseInt(u1, c.next() orelse return bad(gpa, &e), 10) catch return bad(gpa, &e);
            if (down < -1 or down >= std.math.maxInt(u32)) return bad(gpa, &e);
            try e.sk.nodes.append(gpa, .{ .x = x, .y = y, .layer = layer, .r = r, .down = if (down < 0) none else @intCast(down), .tip = tip == 1 });
        }
        if (!e.sk.valid(std.math.maxInt(u32))) return bad(gpa, &e);
        return e;
    }

    fn bad(gpa: Allocator, e: *Edit) ?Edit {
        e.deinit(gpa);
        e.* = .{ .shape = e.shape, .layers = e.layers };
        return null;
    }
};

const testing = std.testing;

test "a straight path keeps only its ends, and a bend keeps its corner" {
    const gpa = testing.allocator;
    var s: Skeleton = .{};
    defer s.deinit(gpa);
    var pts: [11]Disk = undefined;
    for (&pts, 0..) |*p, k| p.* = .{ .x = @floatFromInt(100 * k), .y = 0, .r = 500 + @as(f64, @floatFromInt(10 * k)) };
    const keep = @as([11]bool, @splat(false));
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

/// Two tips that join into a trunk: tip 0 (layer 20) to node 1 (layer
/// 10), tip 2 (layer 18) to node 1, and node 1 to the foot 3 (layer 0).
fn testTree(gpa: Allocator) !Skeleton {
    var s: Skeleton = .{};
    errdefer s.deinit(gpa);
    try s.nodes.appendSlice(gpa, &.{
        .{ .x = 0, .y = 0, .layer = 20, .r = 400, .down = 1, .tip = true },
        .{ .x = 1000, .y = 0, .layer = 10, .r = 800, .down = 3 },
        .{ .x = 2000, .y = 0, .layer = 18, .r = 400, .down = 1, .tip = true },
        .{ .x = 1000, .y = 0, .layer = 0, .r = 2000 },
    });
    return s;
}

test "branches: a tip starts a branch, and a join starts the branch under it" {
    const gpa = testing.allocator;
    var s = try testTree(gpa);
    defer s.deinit(gpa);
    const ids = try s.branches(gpa);
    defer gpa.free(ids);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 1 }, ids);
    const br = try s.branchOf(gpa, 3);
    defer gpa.free(br);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, br);
    const top = try s.topTips(gpa);
    defer gpa.free(top);
    try testing.expectEqualSlices(u32, &.{ 20, 20, 18, 20 }, top);
    // The trunk goes with all branches over it; a tip goes alone.
    var t = try s.clone(gpa);
    defer t.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try t.removeBranch(gpa, 2));
    try testing.expectEqual(@as(u32, 1), t.nodes.items[0].down);
    try testing.expectEqual(@as(u32, 2), t.nodes.items[1].down);
    try testing.expectEqual(@as(usize, 4), try s.removeBranch(gpa, 1));
}

test "edit: the text round-trips exactly, and a bad text is null" {
    const gpa = testing.allocator;
    var e: Edit = .{ .sk = try testTree(gpa), .shape = .{ 10.5, 3, 20, 0.1, -0.2, 9.75, 1e-3 }, .layers = 0xabc };
    defer e.deinit(gpa);
    e.sk.nodes.items[1].x = 1000.123456789;
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try e.write(&w.writer);
    var back = (try Edit.read(gpa, w.written())).?;
    defer back.deinit(gpa);
    try testing.expectEqual(e.layers, back.layers);
    try testing.expectEqualSlices(f64, &e.shape, &back.shape);
    try testing.expectEqualSlices(Node, e.sk.nodes.items, back.sk.nodes.items);
    try testing.expect(try Edit.read(gpa, "abc\t1,2,3,4,5,6,7\t0,0,5,100,0,0") == null);
    try testing.expect(try Edit.read(gpa, "zz") == null);
}
