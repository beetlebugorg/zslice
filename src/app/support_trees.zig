//! The support trees of the user in the app: tree support that the user
//! edits by hand (the support editor).
//!
//! A slice plans the trees of each part, and each engine job keeps them
//! (engine.Job.trees). The first edit of a part copies the planned trees
//! of its last slice into the trees of the user of that part
//! (plate.Part.trees). From then on, the slices of the part use those
//! trees in place of a plan, until a reset of the part.
//!
//! The trees of the user are relative to the center of the footprint of
//! the part, so they move with it. They go into the plate 3MF as a
//! "support_tree" line of the overrides text (so a project file, the
//! session, and an undo keep them), and into the history facts.
//!
//! The trees no longer fit after a turn or a scale of the part (its shape
//! changes, see plate.Part.shape), or after a change of the layers (the
//! layer of a node then means another height, see engine.layersKey). The
//! app then drops them, plans the trees again, and keeps a note for the
//! shell (`takeNote`).
//!
//! Each edit needs the last slice: its layers, its outlines (the limits,
//! see support_edit.zig), and its trees. Without a slice result, an edit
//! returns error.Busy.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = @import("../app.zig").App;
const skel = zs.support_skeleton;
const edit = zs.support_edit;
const Skeleton = skel.Skeleton;

pub const Error = edit.Error || error{ Busy, NoPart };

/// The trees of a part for a shell: the nodes, and the move from their
/// coordinates to the plate (µm).
pub const View = struct {
    sk: *const Skeleton,
    dx: f64,
    dy: f64,
    /// The job of the last slice of the part: the z of each layer.
    job: *const zs.engine.Job,
    /// The trees of the user (else the trees of the plan).
    edited: bool,
};

/// The job and the move of part i in the last slice, or null.
fn jobOf(app: *const App, part: usize) ?struct { job: *const zs.engine.Job, dx: f64, dy: f64 } {
    if (app.getState() != .done) return null;
    const pj = if (app.job) |*j| j else return null;
    const inst = pj.instanceOf(@intCast(part)) orelse return null;
    return .{ .job = &pj.groups[inst.group].job, .dx = @floatFromInt(inst.dx), .dy = @floatFromInt(inst.dy) };
}

/// The trees of part i that the view shows, or null with no slice.
pub fn view(app: *App, part: usize) ?View {
    check(app);
    if (part >= app.plate.count()) return null;
    const j = jobOf(app, part) orelse return null;
    const p = &app.plate.parts.items[part];
    if (p.trees) |*t| return .{ .sk = &t.sk, .dx = p.x * 1000, .dy = p.y * 1000, .job = j.job, .edited = true };
    return .{ .sk = &j.job.trees, .dx = j.dx, .dy = j.dy, .job = j.job, .edited = false };
}

/// One node of the trees of a part for a shell (see `nodes`).
pub const NodeInfo = struct {
    /// The center on the plate, and the top z of its layer (mm).
    x: f64,
    y: f64,
    z: f64,
    /// The radius, and the least radius that the rules allow (mm).
    r: f64,
    r_min: f64,
    /// The next node toward the bed, or -1.
    down: i32,
    layer: u32,
    /// The branch of the node (see support_skeleton.Skeleton.branches).
    branch: u32,
    flags: u32,

    pub const tip: u32 = 1;
    /// The root of a tree on the bed.
    pub const foot: u32 = 2;
    /// The root of a tree that rests on the part.
    pub const rests: u32 = 4;
};

/// The nodes of the trees of part i that the view shows, in `out` (at
/// most out.len). Returns the count of all nodes, or null with no slice.
pub fn nodes(app: *App, part: usize, out: []NodeInfo) Allocator.Error!?usize {
    const v = view(app, part) orelse return null;
    const items = v.sk.nodes.items;
    if (out.len == 0) return items.len;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ids = try v.sk.branches(a);
    const tops = try v.sk.topTips(a);
    const job = v.job;
    const r = &job.resolved;
    const n = job.layers.len;
    const z = try a.alloc(f64, n);
    const h = try a.alloc(f64, n);
    for (job.layers, z, h) |l, *zz, *hh| {
        zz.* = l.z * 1000;
        hh.* = l.height * 1000;
    }
    const c: edit.Ctx = .{ .a = a, .params = zs.support.treeParams(r), .z = z, .h = h, .outlines = job.outlines, .xy = 0, .xy_under = 0, .tips_below = 0 };
    for (items[0..@min(items.len, out.len)], out[0..@min(items.len, out.len)], 0..) |nd, *o, k| {
        const layer = @min(nd.layer, @as(u32, @intCast(n -| 1)));
        var flags: u32 = 0;
        if (nd.tip) flags |= NodeInfo.tip;
        if (nd.down == skel.none) flags |= if (nd.layer == 0) NodeInfo.foot else NodeInfo.rests;
        o.* = .{
            .x = (v.dx + nd.x) / 1000,
            .y = (v.dy + nd.y) / 1000,
            .z = if (n > 0) job.layers[layer].z else 0,
            .r = nd.r / 1000,
            .r_min = if (n > 0) c.ruleRadius(@min(@max(tops[k], layer), @as(u32, @intCast(n - 1))), layer) / 1000 else 0,
            .down = if (nd.down == skel.none) -1 else @intCast(nd.down),
            .layer = nd.layer,
            .branch = ids[k],
            .flags = flags,
        };
    }
    return items.len;
}

/// Drops the trees of the user that no longer fit their part, with a
/// note. The shape needs no slice; the layers need the last slice.
pub fn check(app: *App) void {
    for (app.plate.parts.items, 0..) |*p, i| {
        const t = &(p.trees orelse continue);
        var why: ?[]const u8 = null;
        if (!zs.plate.sameShape(t.shape, p.shape())) {
            why = "the part turned or changed its size";
        } else if (jobOf(app, i)) |j| {
            // A coarse slice (a drag) has other layers for a moment.
            const coarse = app.coarse_part != null and app.coarse_part.? == i;
            if (!coarse and j.job.trees_dropped and j.job.layers_key != t.layers) why = "the layers changed";
        }
        const w = why orelse continue;
        t.deinit(app.gpa);
        p.trees = null;
        setNote(app, p.name, w);
    }
}

fn setNote(app: *App, name: []const u8, why: []const u8) void {
    app.trees_note.clearRetainingCapacity();
    app.trees_note.print(app.gpa, "The support of {s} was planned again: {s}.", .{ name, why }) catch {};
}

/// The note of the last drop of the trees of the user, or null. The
/// note goes after this call; the text is valid until the next change.
pub fn takeNote(app: *App) ?[]const u8 {
    if (app.trees_note.items.len == 0) return null;
    app.trees_note_out.clearRetainingCapacity();
    app.trees_note_out.appendSlice(app.gpa, app.trees_note.items) catch return null;
    app.trees_note.clearRetainingCapacity();
    return app.trees_note_out.items;
}

/// The trees of the user of part i. The first edit copies the trees of
/// the last slice.
fn userTrees(app: *App, part: usize) Error!*skel.Edit {
    if (part >= app.plate.count()) return error.NoPart;
    check(app);
    const p = &app.plate.parts.items[part];
    if (p.trees) |*t| return t;
    const j = jobOf(app, part) orelse return error.Busy;
    var e: skel.Edit = .{ .shape = p.shape(), .layers = j.job.layers_key };
    errdefer e.deinit(app.gpa);
    try e.sk.appendMoved(app.gpa, &j.job.trees, j.dx - p.x * 1000, j.dy - p.y * 1000);
    p.trees = e;
    return &p.trees.?;
}

/// The limits of the edits of part i, in `a` (an arena).
fn ctxOf(app: *App, a: Allocator, part: usize) Error!edit.Ctx {
    const j = jobOf(app, part) orelse return error.Busy;
    const job = j.job;
    const r = &job.resolved;
    const n = job.layers.len;
    const z = try a.alloc(f64, n);
    const h = try a.alloc(f64, n);
    for (job.layers, z, h) |l, *zz, *hh| {
        zz.* = l.z * 1000;
        hh.* = l.height * 1000;
    }
    const gaps = zs.support.xyGaps(r);
    const cache = &job.support_cache;
    const p = &app.plate.parts.items[part];
    return .{
        .a = a,
        .params = zs.support.treeParams(r),
        .z = z,
        .h = h,
        .outlines = job.outlines,
        .blocked = if (cache.blocked.len == n) cache.blocked else &.{},
        .near = if (cache.near.len == n) cache.near else &.{},
        .xy = gaps[0],
        .xy_under = gaps[1],
        .tips_below = zs.support.tipsBelow(r),
        // From the trees of the user to the frame of the job.
        .ox = p.x * 1000 - j.dx,
        .oy = p.y * 1000 - j.dy,
    };
}

/// An edit of the trees of part i: `f(ctx, skeleton, args)` with the
/// trees of the user. Returns the result of `f`.
fn run(app: *App, part: usize, comptime f: anytype, args: anytype) Error!ResultOf(f) {
    if (part >= app.plate.count()) return error.NoPart;
    // The limits need the slice: check it before the first copy.
    if (jobOf(app, part) == null) return error.Busy;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var c = try ctxOf(app, arena.allocator(), part);
    const t = try userTrees(app, part);
    return @call(.auto, f, .{ &c, &t.sk } ++ args);
}

fn ResultOf(comptime f: anytype) type {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return @typeInfo(R).error_union.payload;
}

fn um(mm: f64) f64 {
    return mm * 1000;
}

/// Moves node i of the trees of part `part` to (x, y) on the plate (mm).
/// Returns the Clamp bits (support_edit.Clamp).
pub fn moveNode(app: *App, part: usize, node: u32, x: f64, y: f64) Error!u32 {
    const p = &app.plate.parts.items[@min(part, app.plate.count() -| 1)];
    return run(app, part, edit.moveNode, .{ node, um(x) - p.x * 1000, um(y) - p.y * 1000 });
}

/// Sets the radius of node i (mm). Returns the Clamp bits.
pub fn setRadius(app: *App, part: usize, node: u32, r: f64) Error!u32 {
    return run(app, part, edit.setRadius, .{ node, um(r) });
}

/// Moves the branch of node i by (dx, dy) mm. Returns the Clamp bits.
pub fn moveBranch(app: *App, part: usize, node: u32, dx: f64, dy: f64) Error!u32 {
    return run(app, part, edit.moveBranch, .{ node, um(dx), um(dy) });
}

fn deleteIn(c: *edit.Ctx, sk: *Skeleton, node: u32) edit.Error!usize {
    return edit.deleteBranch(c.a, sk, node);
}

/// Deletes the branch of node i and the branches over it. Returns the
/// count of nodes that went.
pub fn deleteBranch(app: *App, part: usize, node: u32) Error!usize {
    return run(app, part, deleteIn, .{node});
}

fn addIn(c: *edit.Ctx, sk: *Skeleton, gpa: Allocator, f: [2]f64, t: [3]f64) edit.Error!edit.Added {
    return edit.addBranch(gpa, c, sk, f[0], f[1], t[0], t[1], t[2]);
}

/// Adds a branch from the bed point (fx, fy) to the point (tx, ty, tz) of
/// the part (mm, on the plate). Returns its tip node and the Clamp bits.
pub fn addBranch(app: *App, part: usize, fx: f64, fy: f64, tx: f64, ty: f64, tz: f64) Error!edit.Added {
    if (part >= app.plate.count()) return error.NoPart;
    const p = &app.plate.parts.items[part];
    const ox = p.x * 1000;
    const oy = p.y * 1000;
    return run(app, part, addIn, .{ app.gpa, [2]f64{ um(fx) - ox, um(fy) - oy }, [3]f64{ um(tx) - ox, um(ty) - oy, um(tz) } });
}

/// The planned trees again for part i. False if it had no trees of the
/// user.
pub fn reset(app: *App, part: usize) bool {
    if (part >= app.plate.count()) return false;
    const p = &app.plate.parts.items[part];
    const t = &(p.trees orelse return false);
    t.deinit(app.gpa);
    p.trees = null;
    return true;
}

/// True if the trees of the user of part i hold it up: its center of mass
/// is over the foot of the part and the tips of the trees that stand on
/// the bed (physics.holdMargin). True with no trees of the user.
pub fn holds(app: *App, part: usize) Allocator.Error!bool {
    if (part >= app.plate.count()) return true;
    const p = &app.plate.parts.items[part];
    const t = &(p.trees orelse return true);
    var props: std.ArrayList([2]f64) = .empty;
    defer props.deinit(app.gpa);
    for (t.sk.nodes.items, 0..) |nd, k| {
        if (!nd.tip) continue;
        if (t.sk.nodes.items[t.sk.root(@intCast(k))].layer != 0) continue;
        try props.append(app.gpa, .{ p.x + nd.x / 1000, p.y + nd.y / 1000 });
    }
    // The mesh at its place on the plate, as the props are.
    var m = try app.plate.partMesh(app.gpa, part);
    defer m.deinit(app.gpa);
    return try zs.physics.holdMargin(app.gpa, &m, props.items) >= -1e-3;
}

/// The lines of the trees of the user in the overrides text of a 3MF file:
/// "support_tree <tab> part <tab> ..." (see support_skeleton.Edit.write).
pub fn write3mfLines(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (app.plate.parts.items, 0..) |p, i| {
        const t = &(p.trees orelse continue);
        try w.print("support_tree\t{d}\t", .{i});
        try t.write(w);
        try w.writeByte('\n');
    }
}

/// Reads one line of the overrides text: the trees of part `first` + the
/// part of the line. False if it is not a trees line. A bad line is left
/// out.
pub fn read3mfLine(app: *App, first: usize, line: []const u8) Allocator.Error!bool {
    const tag = "support_tree\t";
    if (!std.mem.startsWith(u8, line, tag)) return false;
    const rest = line[tag.len..];
    const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return true;
    const k = std.fmt.parseInt(usize, rest[0..tab], 10) catch return true;
    const i = first + k;
    if (i >= app.plate.count()) return true;
    const e = (try skel.Edit.read(app.gpa, rest[tab + 1 ..])) orelse return true;
    const p = &app.plate.parts.items[i];
    if (p.trees) |*old| old.deinit(app.gpa);
    p.trees = e;
    return true;
}

/// The facts of the trees for the history: a line for each part with
/// trees of the user. The value changes with each edit.
pub fn writeFacts(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    for (app.plate.parts.items) |p| {
        const t = &(p.trees orelse continue);
        const ids = t.sk.branches(arena.allocator()) catch return error.WriteFailed;
        var n: u32 = 0;
        for (ids) |b| n = @max(n, b + 1);
        try w.print("part:{s}\t(support trees)\tedited, {d} branches, {d} nodes ({x:0>4})\n", .{ p.name, n, t.sk.nodes.items.len, t.sk.hash() & 0xffff });
    }
}

const testing = std.testing;

/// An app with a mushroom (a 4 mm post, a 20 mm cap from z 5 to 7) and
/// tree support.
fn mushroom(gpa: Allocator) !*App {
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try zs.mesh.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    const app = try App.create(gpa, null, null);
    errdefer app.destroy();
    try app.loadStl("mushroom.stl", bytes.written());
    try app.setSetting("project.support", "everywhere");
    try app.setSetting("project.support_style", "tree");
    try slice(app);
    return app;
}

fn slice(app: *App) !void {
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(@import("../app.zig").State.done, app.getState());
}

/// The trees of the last slice of part 0, on the plate (µm).
fn sliced(app: *App, gpa: Allocator) !Skeleton {
    const j = jobOf(app, 0).?;
    var s: Skeleton = .{};
    try s.appendMoved(gpa, &j.job.trees, j.dx, j.dy);
    return s;
}

/// The trees that the view shows, on the plate (µm).
fn shown(app: *App, gpa: Allocator) !Skeleton {
    const v = view(app, 0).?;
    var s: Skeleton = .{};
    try s.appendMoved(gpa, v.sk, v.dx, v.dy);
    return s;
}

fn expectSame(a: *const Skeleton, b: *const Skeleton) !void {
    try testing.expectEqual(a.nodes.items.len, b.nodes.items.len);
    for (a.nodes.items, b.nodes.items) |p, q| {
        try testing.expectApproxEqAbs(p.x, q.x, 1e-6);
        try testing.expectApproxEqAbs(p.y, q.y, 1e-6);
        try testing.expectEqual(p.layer, q.layer);
        try testing.expectEqual(p.r, q.r);
        try testing.expectEqual(p.down, q.down);
    }
}

test "support trees: an edit stays after a slice, a 3MF file, a move, and an undo" {
    const gpa = testing.allocator;
    const app = try mushroom(gpa);
    defer app.destroy();
    _ = app.undo.commit(app, 0);
    const planned = try gpa.dupe(u8, app.gcode().?);
    defer gpa.free(planned);
    var before = try shown(app, gpa);
    defer before.deinit(gpa);
    try testing.expect(before.nodes.items.len > 4);
    try testing.expect(!view(app, 0).?.edited);

    // Delete the branch of the first tip, and make a node wider.
    const tip: u32 = for (before.nodes.items, 0..) |nd, k| {
        if (nd.tip) break @intCast(k);
    } else unreachable;
    try testing.expect(try deleteBranch(app, 0, tip) >= 1);
    const v = view(app, 0).?;
    try testing.expect(v.edited);
    try testing.expect(v.sk.nodes.items.len < before.nodes.items.len);
    const root = v.sk.root(0);
    _ = try setRadius(app, 0, root, v.sk.nodes.items[root].r - 200);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    var edited = try shown(app, gpa);
    defer edited.deinit(gpa);

    // A slice uses the trees of the user: the same trees, other G-code.
    try slice(app);
    var used = try sliced(app, gpa);
    defer used.deinit(gpa);
    try expectSame(&edited, &used);
    try testing.expect(!std.mem.eql(u8, planned, app.gcode().?));
    const g_edit = try gpa.dupe(u8, app.gcode().?);
    defer gpa.free(g_edit);

    // The facts name the trees.
    var facts: std.Io.Writer.Allocating = .init(gpa);
    defer facts.deinit();
    try app.writeFacts(&facts.writer);
    try testing.expect(std.mem.indexOf(u8, facts.written(), "\t(support trees)\tedited, ") != null);

    // The 3MF file keeps the trees: a new app slices the same G-code.
    const file = try app.write3mfAlloc(gpa);
    defer gpa.free(file);
    const other = try App.create(gpa, null, null);
    defer other.destroy();
    other.keep_places = true;
    try other.loadStl("plate.3mf", file);
    try other.setSetting("project.support", "everywhere");
    try other.setSetting("project.support_style", "tree");
    try testing.expect(other.plate.parts.items[0].trees != null);
    try slice(other);
    try testing.expectEqualStrings(g_edit, other.gcode().?);

    // A move of the part moves the trees with it.
    const p = &app.plate.parts.items[0];
    app.plate.move(0, p.x + 10, p.y + 5);
    try slice(app);
    var moved = try sliced(app, gpa);
    defer moved.deinit(gpa);
    try testing.expectEqual(edited.nodes.items.len, moved.nodes.items.len);
    for (edited.nodes.items, moved.nodes.items) |a, b| {
        try testing.expectApproxEqAbs(a.x + 10_000, b.x, 1e-6);
        try testing.expectApproxEqAbs(a.y + 5_000, b.y, 1e-6);
    }
    app.plate.move(0, p.x - 10, p.y - 5);

    // Undo: the planned trees; redo: the trees of the user again.
    _ = app.undo.undo(app, 2000);
    try testing.expect(app.plate.parts.items[0].trees == null);
    _ = app.undo.redo(app, 3000);
    try testing.expect(app.plate.parts.items[0].trees != null);
    try slice(app);
    try testing.expectEqualStrings(g_edit, app.gcode().?);

    // Other layers: the trees go, with a note.
    try app.setSetting("project.layer_height", "0.3");
    try slice(app);
    try testing.expect(view(app, 0) != null);
    try testing.expect(app.plate.parts.items[0].trees == null);
    try testing.expect(std.mem.indexOf(u8, takeNote(app).?, "the layers changed") != null);
    try testing.expect(takeNote(app) == null);

    // A turn of the part: the trees go too.
    _ = try deleteBranch(app, 0, 0);
    app.plate.rotate(0, 45);
    check(app);
    try testing.expect(app.plate.parts.items[0].trees == null);
    try testing.expect(std.mem.indexOf(u8, takeNote(app).?, "turned") != null);
}

test "support trees: a branch from the bed holds the overhang over it" {
    const gpa = testing.allocator;
    const app = try mushroom(gpa);
    defer app.destroy();
    // No trees at all.
    while (view(app, 0).?.sk.nodes.items.len > 0) _ = try deleteBranch(app, 0, 0);
    try slice(app);
    const p = &app.plate.parts.items[0];
    // A point under the cap, 7 mm out from the post on both axes.
    const tx = p.x + 7;
    const ty = p.y + 7;
    const held = struct {
        fn f(a: *App, x: f64, y: f64) !bool {
            const job = jobOf(a, 0).?.job;
            // The layer at 3 mm.
            var j: usize = 0;
            while (job.layers[j].z < 3) j += 1;
            if (job.support.len == 0) return false;
            return zs.geom.insideAny(job.support[j].body, .{ .x = zs.geom.fromMm(x), .y = zs.geom.fromMm(y) });
        }
    }.f;
    try testing.expect(!try held(app, tx, ty));
    const got = try addBranch(app, 0, tx + 1, ty, tx, ty, 5);
    try testing.expectEqual(@as(u32, 0), got.clamp);
    try slice(app);
    try testing.expect(try held(app, tx, ty));
    // The pad under the cap holds over the tip.
    const job = jobOf(app, 0).?.job;
    var pad = false;
    for (job.support) |l| {
        if (zs.geom.insideAny(l.interface, .{ .x = zs.geom.fromMm(tx), .y = zs.geom.fromMm(ty) })) pad = true;
    }
    try testing.expect(pad);
    // Reset: the planned trees again.
    try testing.expect(reset(app, 0));
    try testing.expect(view(app, 0).?.edited == false);
}

test "support trees: a part falls when the branch that holds it goes" {
    const gpa = testing.allocator;
    // A slab of 20 x 4 mm on a post of 2 x 2 mm at one end: it stands only
    // on its support.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 2, 2, 5);
    try zs.mesh.shapes.addBox(&b, -4, -1, 5, 16, 3, 9);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    // Support first: with support off, the slab falls over on the load.
    try app.setSetting("project.support", "everywhere");
    try app.setSetting("project.support_style", "tree");
    try app.loadStl("slab.stl", bytes.written());
    try slice(app);
    try testing.expect(try app.unstablePart() == null);
    // No branches: it falls.
    while (view(app, 0).?.sk.nodes.items.len > 0) _ = try deleteBranch(app, 0, 0);
    try testing.expectEqual(@as(?usize, 0), try app.unstablePart());
    // A branch under the far end of the slab: it stands again.
    const box = app.plate.parts.items[0].footprint();
    const x = box[2] - 2;
    const y = (box[1] + box[3]) / 2;
    _ = try addBranch(app, 0, x, y, x, y, 5);
    try testing.expect(try app.unstablePart() == null);
}
