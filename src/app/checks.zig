//! The printability check of the last slice: things that can make a print
//! fail, or print badly, that the lines do not show at a glance.
//!
//! - flow: a line that needs more plastic per second than near the limit
//!   of the hot end (filament.max_flow): the hot end cannot melt it, and
//!   the line comes out thin.
//! - cooling: a layer that prints in less than filament.min_layer_time,
//!   also at filament.min_speed: the plastic is still soft when the next
//!   layer comes.
//! - overhang: with support off, an area of a layer that hangs out past the
//!   layer below at a slope flatter than project.support_angle (the
//!   overhang of more than height × tan(angle)), wider than a line.
//! - bridge: a piece of a layer over air that is held at two or more
//!   sides by the layer below, with its span (a note; a warning when it is
//!   long).
//! - island: a shape that starts in the air (islands.zig).
//! - retractions: a layer with very many retractions: they grind the
//!   filament at one place of the feeder.
//!
//! Each issue has its kind, its layer, a place, the line it is about (or
//! none), a number for its size, and a text that says what and why. The
//! check runs on demand, and the app keeps the result until the next
//! slice.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const Allocator = std.mem.Allocator;
const Toolpaths = @import("toolpaths.zig").Toolpaths;
const geom = zs.geom;

pub const Kind = enum(u8) { flow, cooling, overhang, island, retractions, bridge };

pub const Issue = extern struct {
    kind: Kind,
    /// 0 note, 1 warning, 2 problem.
    severity: u8,
    layer: u32,
    /// The path the issue is about, or no_path.
    path: u32,
    x: f64,
    y: f64,
    /// The size: flow in % of max_flow, layer time in s, overhang area in
    /// mm², island area in mm², retractions.
    value: f64,
    /// The text, in Result.text[text_start..][0..text_len].
    text_start: u32,
    text_len: u32,

    pub const no_path = std.math.maxInt(u32);
};

pub const Result = struct {
    issues: []Issue,
    text: []u8,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.issues);
        gpa.free(r.text);
    }

    pub fn textOf(r: Result, i: Issue) []const u8 {
        return r.text[i.text_start..][0..i.text_len];
    }
};

const Builder = struct {
    gpa: Allocator,
    issues: std.ArrayList(Issue) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn add(b: *Builder, issue: Issue, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        var i = issue;
        i.text_start = @intCast(b.text.items.len);
        try b.text.print(b.gpa, fmt, args);
        i.text_len = @intCast(b.text.items.len - i.text_start);
        try b.issues.append(b.gpa, i);
    }
};

/// The most issues of one kind: the worst first.
const max_per_kind = 50;

/// The checks of the slice. `job` gives the outlines (for the overhangs)
/// and the islands; `t` the lines and their times; `s` the settings of the
/// print.
pub fn run(gpa: Allocator, job: *const zs.engine.Job, t: *const Toolpaths, s: zs.Settings) Allocator.Error!Result {
    var b: Builder = .{ .gpa = gpa };
    errdefer {
        b.issues.deinit(gpa);
        b.text.deinit(gpa);
    }
    try flowIssues(&b, job, t);
    try coolingIssues(&b, job, t);
    try overhangIssues(&b, job, s);
    try islandIssues(&b, job);
    try retractionIssues(&b, t);
    // The worst first: problems, then warnings, then by layer.
    std.mem.sort(Issue, b.issues.items, {}, struct {
        fn lt(_: void, x: Issue, y: Issue) bool {
            if (x.severity != y.severity) return x.severity > y.severity;
            return x.layer < y.layer;
        }
    }.lt);
    return .{ .issues = try b.issues.toOwnedSlice(gpa), .text = try b.text.toOwnedSlice(gpa) };
}

fn midpoint(t: *const Toolpaths, path: usize) [2]f64 {
    const a = t.pathStart(path);
    const e = t.path_ends.items[path];
    const m = a + (e - a) / 2;
    return .{ t.points.items[2 * m], t.points.items[2 * m + 1] };
}

fn flowIssues(b: *Builder, job: *const zs.engine.Job, t: *const Toolpaths) Allocator.Error!void {
    const Hit = struct { path: u32, layer: u32, ratio: f64, flow: f64, limit: f64 };
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(b.gpa);
    for (0..t.path_ends.items.len) |p| {
        const dt: f64 = t.path_end_time.items[p] - t.path_start_time.items[p];
        if (!(dt > 0.05)) continue;
        const layer = t.layerOfPath(p) orelse continue;
        const limit = job.resolvedAt(layer).settings.filament.max_flow;
        if (!(limit > 0)) continue;
        const flow = @as(f64, t.path_area.items[p]) * t.pathLength(p) / dt;
        const ratio = flow / limit;
        if (ratio > 0.95) try hits.append(b.gpa, .{ .path = @intCast(p), .layer = @intCast(layer), .ratio = ratio, .flow = flow, .limit = limit });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, x: Hit, y: Hit) bool {
            return x.ratio > y.ratio;
        }
    }.lt);
    for (hits.items[0..@min(hits.items.len, max_per_kind)]) |h| {
        const c = midpoint(t, h.path);
        try b.add(.{ .kind = .flow, .severity = if (h.ratio > 1.0) 2 else 1, .layer = h.layer, .path = h.path, .x = c[0], .y = c[1], .value = h.ratio * 100, .text_start = 0, .text_len = 0 },
            "Layer {d}: a line needs {d:.1} mm³/s, {d:.0} % of what the hot end melts ({d:.1} mm³/s, filament.max_flow). It can come out thin. Lower its speed, or raise max_flow if the hot end can do more.", .{ h.layer + 1, h.flow, h.ratio * 100, h.limit });
    }
}

fn coolingIssues(b: *Builder, job: *const zs.engine.Job, t: *const Toolpaths) Allocator.Error!void {
    var n: usize = 0;
    for (0..t.layer_ends.items.len) |l| {
        const first: usize = if (l == 0) 0 else t.layer_ends.items[l - 1];
        const last: usize = t.layer_ends.items[l];
        if (last <= first) continue;
        const s = job.resolvedAt(l).settings.filament;
        if (!(s.min_layer_time > 0)) continue;
        const begin: f64 = if (first == 0) 0 else t.path_end_time.items[first - 1];
        const time = t.path_end_time.items[last - 1] - begin;
        if (time >= s.min_layer_time - 0.5) continue;
        n += 1;
        if (n > max_per_kind) break;
        const c = midpoint(t, first);
        try b.add(.{ .kind = .cooling, .severity = 1, .layer = @intCast(l), .path = Issue.no_path, .x = c[0], .y = c[1], .value = time, .text_start = 0, .text_len = 0 },
            "Layer {d} prints in {d:.1} s, less than the minimum layer time ({d:.0} s), also at the minimum speed ({d:.0} mm/s). The plastic can still be soft under the next layer. Print two parts at once, or lower filament.min_speed.", .{ l + 1, time, s.min_layer_time, s.min_speed });
    }
}

/// One piece of a layer that hangs out past the layer below: its area,
/// its center, and, for a bridge, the number of solid areas that hold its
/// edge (2 or more) and its span across the air.
const Hang = struct { layer: u32, area: f64, x: f64, y: f64, anchors: u32, held: f64, span: f64 };

/// The pieces of layer i (i >= 1) that hang out past layer i - 1 farther
/// than height × tan(support_angle), wider than a line. A piece whose edge
/// meets two or more separate solid areas of layer i - 1 is a bridge.
fn hangsOf(gpa: Allocator, job: *const zs.engine.Job, i: usize, angle: f64, out: *std.ArrayList(Hang)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = job.layers[i].height;
    const reach = geom.fromMm(h * @tan(angle));
    const below = try zs.offset.offset(arena, job.outlines[i - 1], reach, .{});
    const hang = try zs.clip.difference(arena, job.outlines[i], below);
    if (hang.isEmpty()) return;
    // Only parts wider than a line: a shrink and a grow by half a line
    // remove the thin edges of a slope.
    const w = geom.fromMm(job.resolvedAt(i).line_width);
    const wide = try zs.offset.opening(arena, hang, @divTrunc(w, 2), .{});
    if (wide.isEmpty()) return;
    // The solid areas under the layer, in the outline of the layer.
    const solid = try zs.clip.intersect(arena, job.outlines[i - 1], job.outlines[i]);
    const pieces = try zs.infill.islandsOf(arena, wide);
    for (pieces) |piece| {
        const area = piece.areaMm2();
        if (area < 1.0) continue;
        // The solid areas that the edge of the piece meets: the piece grown
        // by a line, in the solid area.
        // The piece starts `reach` past the solid edge: grow it by that and
        // a line, so the band in the solid area is a line wide.
        const grown = try zs.offset.offset(arena, piece, reach + w, .{});
        const touch = try zs.clip.intersect(arena, grown, solid);
        var anchors: u32 = 0;
        var touch_area: f64 = 0;
        for (0..touch.count()) |k| {
            const ta = geom.areaMm2(touch.get(k));
            if (ta > 0.05) anchors += 1;
            touch_area += ta;
        }
        // The part of the edge that rests on solid plastic: the length of
        // the contact (its area over the width of the band) over the
        // length of the edge.
        var edge: f64 = 0;
        for (0..piece.count()) |k| {
            const poly = piece.get(k);
            for (poly, 0..) |q, qi| edge += geom.Point.dist(q, poly[(qi + 1) % poly.len]);
        }
        const held = if (edge > 0) @min(1.0, touch_area / geom.toMm(w) / geom.toMm(@intFromFloat(edge))) else 0;
        const box = piece.bounds();
        const bw = geom.toMm(box.max.x - box.min.x);
        const bh = geom.toMm(box.max.y - box.min.y);
        try out.append(gpa, .{
            .layer = @intCast(i),
            .area = area,
            .x = geom.toMm(@divTrunc(box.min.x + box.max.x, 2)),
            .y = geom.toMm(@divTrunc(box.min.y + box.max.y, 2)),
            .anchors = anchors,
            .held = held,
            // The span of a bridge: the short side of its box.
            .span = @min(bw, bh),
        });
    }
}

fn overhangIssues(b: *Builder, job: *const zs.engine.Job, s: zs.Settings) Allocator.Error!void {
    if (s.project.support != .off) return;
    const n = job.outlines.len;
    if (n < 2) return;
    const angle = std.math.degreesToRadians(s.project.support_angle);
    // The layers on all threads, each into its own list.
    const lists = try b.gpa.alloc(std.ArrayList(Hang), n);
    defer {
        for (lists) |*l| l.deinit(b.gpa);
        b.gpa.free(lists);
    }
    for (lists) |*l| l.* = .empty;
    const Pass = struct {
        job: *const zs.engine.Job,
        lists: []std.ArrayList(Hang),
        angle: f64,
        gpa: Allocator,
        fn run(c: *const @This(), i: usize) anyerror!void {
            if (i == 0) return;
            try hangsOf(c.gpa, c.job, i, c.angle, &c.lists[i]);
        }
    };
    const c: Pass = .{ .job = job, .lists = lists, .angle = angle, .gpa = b.gpa };
    zs.parallel.forEach(job.threads, n, &c, Pass.run) catch |e| return @as(Allocator.Error, @errorCast(e));
    var hits: std.ArrayList(Hang) = .empty;
    defer hits.deinit(b.gpa);
    for (lists) |l| try hits.appendSlice(b.gpa, l.items);
    // The largest first; one issue for each run of layers at one place.
    std.mem.sort(Hang, hits.items, {}, struct {
        fn lt(_: void, x: Hang, y: Hang) bool {
            return x.area > y.area;
        }
    }.lt);
    var shown: std.ArrayList(Hang) = .empty;
    defer shown.deinit(b.gpa);
    for (hits.items) |hh| {
        var near = false;
        for (shown.items) |o| near = near or (@abs(@as(i64, o.layer) - @as(i64, hh.layer)) < 10 and @abs(o.x - hh.x) < 5 and @abs(o.y - hh.y) < 5);
        if (near) continue;
        try shown.append(b.gpa, hh);
        if (shown.items.len > max_per_kind) break;
        // A bridge: held at two or more places, or along most of its edge
        // (a roof held all around). An overhang is held at one side.
        if (hh.anchors >= 2 or hh.held >= 0.6) {
            try b.add(.{ .kind = .bridge, .severity = if (hh.span > 15) 1 else 0, .layer = hh.layer, .path = Issue.no_path, .x = hh.x, .y = hh.y, .value = hh.span, .text_start = 0, .text_len = 0 },
                "Layer {d}: a bridge of about {d:.1} mm over air ({d:.1} mm²), held along {d:.0} % of its edge. A long bridge can sag; it prints best slow, with the fan on.", .{ hh.layer + 1, hh.span, hh.area, hh.held * 100 });
        } else {
            try b.add(.{ .kind = .overhang, .severity = if (hh.area > 10) 2 else 1, .layer = hh.layer, .path = Issue.no_path, .x = hh.x, .y = hh.y, .value = hh.area, .text_start = 0, .text_len = 0 },
                "Layer {d}: {d:.1} mm² hang out past the layer below, flatter than {d:.0}° (project.support_angle), with support off. It can sag or curl. Turn on support, or add support there (right click).", .{ hh.layer + 1, hh.area, s.project.support_angle });
        }
    }
}

fn islandIssues(b: *Builder, job: *const zs.engine.Job) Allocator.Error!void {
    for (job.islands[0..@min(job.islands.len, max_per_kind)]) |isl| {
        try b.add(.{ .kind = .island, .severity = 2, .layer = @intCast(isl.layer), .path = Issue.no_path, .x = isl.x, .y = isl.y, .value = isl.area, .text_start = 0, .text_len = 0 },
            "Layer {d}: a shape of {d:.1} mm² starts in the air, with nothing under it. Add support there, or turn the part.", .{ isl.layer + 1, isl.area });
    }
}

fn retractionIssues(b: *Builder, t: *const Toolpaths) Allocator.Error!void {
    var n: usize = 0;
    for (0..t.layer_ends.items.len) |l| {
        const first: usize = if (l == 0) 0 else t.layer_ends.items[l - 1];
        const last: usize = t.layer_ends.items[l];
        var count: usize = 0;
        for (first..last) |p| count += t.path_retract.items[p];
        if (count < 60) continue;
        n += 1;
        if (n > max_per_kind) break;
        const c = midpoint(t, first);
        try b.add(.{ .kind = .retractions, .severity = 0, .layer = @intCast(l), .path = Issue.no_path, .x = c[0], .y = c[1], .value = @floatFromInt(count), .text_start = 0, .text_len = 0 },
            "Layer {d} has {d} retractions. Many retractions grind the filament at one place of the feeder. Combing (project.combing) keeps more travels inside the part.", .{ l + 1, count });
    }
}

test "checks: a bridge between two posts, and a shelf on one post" {
    const gpa = std.testing.allocator;
    // Two posts 10 mm apart with a plate across them (a bridge), and a
    // third post with a plate that sticks out to one side (an overhang).
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 5, 10, 5);
    try zs.mesh.shapes.addBox(&b, 15, 0, 0, 20, 10, 5);
    try zs.mesh.shapes.addBox(&b, 0, 0, 5, 20, 10, 6);
    try zs.mesh.shapes.addBox(&b, 40, 0, 0, 45, 10, 5);
    try zs.mesh.shapes.addBox(&b, 40, 0, 5, 55, 10, 6);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try zs.app.App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("posts.stl", stl.written());
    try app.startSlice();
    app.stopWorkerForTest();
    const r = try app.checks();
    var bridges: usize = 0;
    var overhangs: usize = 0;
    for (r.issues) |i| switch (i.kind) {
        .bridge => {
            bridges += 1;
            try std.testing.expect(i.value > 8 and i.value < 12);
        },
        .overhang => overhangs += 1,
        else => {},
    };
    try std.testing.expect(bridges >= 1);
    try std.testing.expect(overhangs >= 1);
}
