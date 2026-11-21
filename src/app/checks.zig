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
//! - stand: with support off, a part that the bond of its first layer to
//!   the bed holds with little margin, or only with its brim, or not at
//!   all (bond.zig). The app gives the bond test of each part.
//!
//! - color: a region of one filament of a painted part that is too small
//!   to print (less than a line width across): it prints as a blob, or
//!   not at all.
//! - changes: the filament changes of the print, and their time. Many
//!   changes make a long print; with a pause for each change, each one
//!   waits for you.
//! - tower: the prime tower is off the bed, or on a part.
//! - label: a label (label.zig) with strokes thinner than the narrowest
//!   line (they do not print), or with gaps narrower than it (they fill
//!   with the color of the label), with the size of text that prints
//!   clean.
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

pub const Kind = enum(u8) { flow, cooling, overhang, island, retractions, bridge, stand, color, changes, tower, reach, label };

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
    /// mm², island area in mm², retractions, the margin of the bond.
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
    /// The flag of `runWith`, or null.
    cancel: ?*const std.atomic.Value(bool) = null,
    issues: std.ArrayList(Issue) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn canceled(b: *const Builder) bool {
        const c = b.cancel orelse return false;
        return c.load(.acquire);
    }

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
/// print; `stands` the bond test of each part with support off.
pub fn run(gpa: Allocator, job: *const zs.PlateJob, t: *const Toolpaths, s: zs.Settings, stands: []const Stand, stats: zs.Stats) Allocator.Error!Result {
    return runLabels(gpa, job, t, s, stands, stats, &.{});
}

/// `run`, with the labels of the slice.
pub fn runLabels(gpa: Allocator, job: *const zs.PlateJob, t: *const Toolpaths, s: zs.Settings, stands: []const Stand, stats: zs.Stats, labels: []const LabelInput) Allocator.Error!Result {
    return runWith(gpa, job, t, s, stands, stats, labels, null) catch |e| switch (e) {
        error.Canceled => unreachable,
        else => |x| return x,
    };
}

/// `run`, with a flag that stops it (error.Canceled) within a layer of the
/// overhang pass, or between two passes.
pub fn runWith(gpa: Allocator, job: *const zs.PlateJob, t: *const Toolpaths, s: zs.Settings, stands: []const Stand, stats: zs.Stats, labels: []const LabelInput, cancel: ?*const std.atomic.Value(bool)) (Allocator.Error || error{Canceled})!Result {
    var b: Builder = .{ .gpa = gpa, .cancel = cancel };
    errdefer {
        b.issues.deinit(gpa);
        b.text.deinit(gpa);
    }
    try flowIssues(&b, job, t);
    try coolingIssues(&b, job, t);
    if (b.canceled()) return error.Canceled;
    try overhangIssues(&b, job, s);
    if (b.canceled()) return error.Canceled;
    try islandIssues(&b, job);
    try retractionIssues(&b, t);
    try standIssues(&b, stands);
    try colorIssues(&b, job);
    try changeIssues(&b, job, s, stats);
    try reachIssues(&b, job, s);
    try labelIssues(&b, job, s, labels);
    // The worst first: problems, then warnings, then by layer.
    std.mem.sort(Issue, b.issues.items, {}, struct {
        fn lt(_: void, x: Issue, y: Issue) bool {
            if (x.severity != y.severity) return x.severity > y.severity;
            return x.layer < y.layer;
        }
    }.lt);
    return .{ .issues = try b.issues.toOwnedSlice(gpa), .text = try b.text.toOwnedSlice(gpa) };
}

/// A label of the slice (on the bed, see plate.Part.placeLabel), and
/// the name of its part.
pub const LabelInput = struct {
    part: []const u8,
    label: *const zs.label.Label,
};

/// The labels with strokes or gaps narrower than the narrowest line
/// (see `Kind.label`). The share of the shape that an opening by half
/// that width removes does not print; the area that a closing adds
/// prints in the color of the label (see paint_split.Split.labelLayer).
fn labelIssues(b: *Builder, job: *const zs.PlateJob, s: zs.Settings, labels: []const LabelInput) Allocator.Error!void {
    if (labels.len == 0) return;
    const p = s.project;
    const w = job.resolved.line_width;
    const min_wall = if (p.min_wall_line_width > 0) p.min_wall_line_width else 0.85 * s.machine.nozzle_diameter;
    const min_bead = if (p.min_bead_width > 0) p.min_bead_width else min_wall;
    const r = @divTrunc(geom.fromMm(min_bead), 2);
    const font = zs.font.builtin();
    const ratio = zs.font.stemRatio(&font);
    for (labels) |li| {
        if (b.canceled()) return;
        const l = li.label;
        var arena_state = std.heap.ArenaAllocator.init(b.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const shape = zs.label.outline(a, l) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadFont => continue,
        };
        const area = shape.areaMm2();
        if (!(area > 0)) continue;
        const open = try zs.offset.opening(a, shape, r, .{});
        const lost = 1 - open.areaMm2() / area;
        const grown = try zs.offset.offset(a, shape, r, .{});
        const closed = try zs.offset.offset(a, grown, -r, .{});
        const filled = closed.areaMm2() - area;
        // The first layer of the label.
        var layer: u32 = 0;
        for (job.levels, 0..) |lv, k| if (lv.z >= l.origin[2]) {
            layer = @intCast(k);
            break;
        };
        const text = l.firstText();
        var name_buf: [96]u8 = undefined;
        const name = if (text.len > 0) std.fmt.bufPrint(&name_buf, "\u{201c}{s}\u{201d}", .{text[0..@min(text.len, 64)]}) catch "" else l.kind();
        var size_buf: [96]u8 = undefined;
        const size_hint = if (text.len > 0) std.fmt.bufPrint(&size_buf, " Make the text {d:.1} mm tall for clean strokes.", .{2 * w / ratio}) catch "" else "";
        const is: Issue = .{ .kind = .label, .severity = 1, .layer = layer, .path = Issue.no_path, .x = l.origin[0], .y = l.origin[1], .value = lost * 100, .text_start = 0, .text_len = 0 };
        if (lost > 0.02) {
            try b.add(is, "{s}: label {s}: {d:.0} % of its shape is thinner than {d:.2} mm, the narrowest line, and does not print.{s}", .{ li.part, name, lost * 100, min_bead, size_hint });
        } else if (filled > 0.02 * area) {
            var note = is;
            note.severity = 0;
            note.value = filled;
            try b.add(note, "{s}: label {s}: gaps narrower than {d:.2} mm ({d:.1} mm\u{b2}) print in the color of the label.{s}", .{ li.part, name, min_bead, filled, size_hint });
        }
    }
}

/// The bond test of a part, from the app (see bond.zig).
pub const Stand = struct {
    name: []const u8,
    /// The center of the part on the bed.
    x: f64,
    y: f64,
    result: zs.bond.Result,
    /// No side that the part can fall onto stands either: it stays as
    /// it is, and it can come off the bed.
    weak: bool = false,
};

/// A bond that holds less than this many times the load gets a warning.
/// The bond on a real bed varies by more than this (bond.zig).
pub const stand_margin = 2.0;

fn standIssues(b: *Builder, stands: []const Stand) Allocator.Error!void {
    for (stands) |st| {
        const r = st.result;
        var is: Issue = .{ .kind = .stand, .severity = 0, .layer = 0, .path = Issue.no_path, .x = st.x, .y = st.y, .value = r.margin, .text_start = 0, .text_len = 0 };
        if (st.weak or !r.stands) {
            is.severity = 2;
            try b.add(is, "{s}: the push of the nozzle and its weight can tip this part over. The bond of the first layer holds {d:.1} N mm, and the load is {d:.1} N mm. Add a brim or support.", .{ st.name, r.hold, r.load });
        } else if (!r.stands_bare) {
            is.severity = if (r.margin < stand_margin) 1 else 0;
            try b.add(is, "{s}: the brim holds this part. Without the brim, the push of the nozzle or its weight tips it over.", .{st.name});
        } else if (r.margin < stand_margin) {
            is.severity = 1;
            try b.add(is, "{s}: the bond of the first layer holds this part with little margin ({d:.1} times the load). A brim holds it better.", .{ st.name, r.margin });
        }
    }
}

fn midpoint(t: *const Toolpaths, path: usize) [2]f64 {
    const a = t.pathStart(path);
    const e = t.path_ends.items[path];
    const m = a + (e - a) / 2;
    return .{ t.points.items[2 * m], t.points.items[2 * m + 1] };
}

fn flowIssues(b: *Builder, job: *const zs.PlateJob, t: *const Toolpaths) Allocator.Error!void {
    const Hit = struct { path: u32, layer: u32, ratio: f64, flow: f64, limit: f64 };
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(b.gpa);
    for (0..t.path_ends.items.len) |p| {
        const dt: f64 = t.path_end_time.items[p] - t.path_start_time.items[p];
        if (!(dt > 0.05)) continue;
        const layer = t.layerOfPath(p) orelse continue;
        // The limit of the part of the path.
        const part: u32 = if (p < t.path_part.items.len) t.path_part.items[p] else zs.layer.LayerPlan.no_part;
        const limit = job.pathResolved(part, layer, 0).settings.filament.max_flow;
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
        try b.add(.{ .kind = .flow, .severity = if (h.ratio > 1.0) 2 else 1, .layer = h.layer, .path = h.path, .x = c[0], .y = c[1], .value = h.ratio * 100, .text_start = 0, .text_len = 0 }, "Layer {d}: a line needs {d:.1} mm³/s, {d:.0} % of what the hot end melts ({d:.1} mm³/s, filament.max_flow). It can come out thin. Lower its speed, or raise max_flow if the hot end can do more.", .{ h.layer + 1, h.flow, h.ratio * 100, h.limit });
    }
}

/// The layers that print in less than the minimum layer time: one issue
/// for each run of such layers next to each other (a thin tower makes many
/// short layers), with the shortest time of the run.
fn coolingIssues(b: *Builder, job: *const zs.PlateJob, t: *const Toolpaths) Allocator.Error!void {
    var n: usize = 0;
    var run_first: ?usize = null;
    var run_min: f64 = 0;
    var run_at: usize = 0;
    const count = t.layer_ends.items.len;
    for (0..count + 1) |l| {
        var short = false;
        var time: f64 = 0;
        if (l < count) {
            const first: usize = if (l == 0) 0 else t.layer_ends.items[l - 1];
            const last: usize = t.layer_ends.items[l];
            if (last > first) {
                const st = job.levelResolved(l).settings.filament;
                const begin: f64 = if (first == 0) 0 else t.path_end_time.items[first - 1];
                time = t.path_end_time.items[last - 1] - begin;
                short = st.min_layer_time > 0 and time < st.min_layer_time - 0.5;
            }
        }
        if (short) {
            if (run_first == null or time < run_min) {
                run_min = time;
                run_at = l;
            }
            if (run_first == null) run_first = l;
            continue;
        }
        const f = run_first orelse continue;
        run_first = null;
        n += 1;
        if (n > max_per_kind) break;
        const last_l = l - 1;
        const st = job.levelResolved(run_at).settings.filament;
        const first_path: usize = if (run_at == 0) 0 else t.layer_ends.items[run_at - 1];
        const c = midpoint(t, first_path);
        const issue: Issue = .{ .kind = .cooling, .severity = 1, .layer = @intCast(run_at), .path = Issue.no_path, .x = c[0], .y = c[1], .value = run_min, .text_start = 0, .text_len = 0 };
        if (last_l == f) {
            try b.add(issue, "Layer {d} prints in {d:.1} s, less than the minimum layer time ({d:.0} s), also at the minimum speed ({d:.0} mm/s). The plastic can still be soft under the next layer. Print two parts at once, or lower filament.min_speed.", .{ f + 1, run_min, st.min_layer_time, st.min_speed });
        } else {
            try b.add(issue, "Layers {d} to {d} print in less than the minimum layer time ({d:.0} s), down to {d:.1} s at layer {d}, also at the minimum speed ({d:.0} mm/s). The plastic can still be soft under the next layer. Print two parts at once, or lower filament.min_speed.", .{ f + 1, last_l + 1, st.min_layer_time, run_min, run_at + 1, st.min_speed });
        }
    }
}

/// One piece of a layer that hangs out past the layer below: its area,
/// its center, and, for a bridge, the number of solid areas that hold its
/// edge (2 or more) and its span across the air.
const Hang = struct { layer: u32, area: f64, x: f64, y: f64, anchors: u32, held: f64, span: f64 };

/// The pieces of layer i (i >= 1) that hang out past layer i - 1 farther
/// than height × tan(support_angle), wider than a line. A piece whose edge
/// meets two or more separate solid areas of layer i - 1 is a bridge.
// `under`: the plastic under layer `i`, or null for the layer below in the
// job. A painted part prints as one job for each filament: the layer of the
// other filaments under a region holds it up too.
fn hangsOf(gpa: Allocator, job: *const zs.engine.Job, i: usize, under: ?geom.Paths, angle: f64, out: *std.ArrayList(Hang)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lower = under orelse job.outlines[i - 1];
    const h = job.layers[i].height;
    const reach = geom.fromMm(h * @tan(angle));
    const below = try zs.offset.offset(arena, lower, reach, .{});
    const hang = try zs.clip.difference(arena, job.outlines[i], below);
    if (hang.isEmpty()) return;
    // Only parts wider than a line: a shrink and a grow by half a line
    // remove the thin edges of a slope.
    const w = geom.fromMm(job.resolvedAt(i).line_width);
    const wide = try zs.offset.opening(arena, hang, @divTrunc(w, 2), .{});
    if (wide.isEmpty()) return;
    // The solid areas under the layer, in the outline of the layer.
    const solid = try zs.clip.intersect(arena, lower, job.outlines[i]);
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

fn overhangIssues(b: *Builder, pj: *const zs.PlateJob, s: zs.Settings) Allocator.Error!void {
    // The layers of the jobs of all parts with support off, on all threads,
    // each into its own list. The copies of a part share the job.
    const Item = struct { group: u32, layer: u32 };
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(b.gpa);
    for (pj.groups, 0..) |g, gi| {
        if (g.job.resolved.settings.project.support != .off) continue;
        for (1..g.job.outlines.len) |i| try items.append(b.gpa, .{ .group = @intCast(gi), .layer = @intCast(i) });
    }
    if (items.items.len == 0) return;
    const lists = try b.gpa.alloc(std.ArrayList(Hang), items.items.len);
    defer {
        for (lists) |*l| l.deinit(b.gpa);
        b.gpa.free(lists);
    }
    for (lists) |*l| l.* = .empty;
    const Pass = struct {
        pj: *const zs.PlateJob,
        items: []const Item,
        lists: []std.ArrayList(Hang),
        gpa: Allocator,
        b: *const Builder,
        fn run(c: *const @This(), k: usize) anyerror!void {
            // A cancel skips the layers that are left: runWith gives no
            // result.
            if (c.b.canceled()) return;
            const g = &c.pj.groups[c.items[k].group];
            const job = &g.job;
            const i = c.items[k].layer;
            const angle = std.math.degreesToRadians(job.resolved.settings.project.support_angle);
            if (!g.painted) return hangsOf(c.gpa, job, i, null, angle, &c.lists[k]);
            // A painted part: the layer below of all jobs of the part, at
            // the level of the layer below of this job.
            var arena_state = std.heap.ArenaAllocator.init(c.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const level = g.layer_level[i - 1];
            var under: geom.Paths = try job.outlines[i - 1].clone(arena);
            for (c.pj.groups) |*o| {
                if (o == g or o.part != g.part or !o.painted) continue;
                for (o.layer_level, 0..) |lv, j| if (lv == level) {
                    under = try zs.clip.unite(arena, under, o.job.outlines[j]);
                    break;
                };
            }
            try hangsOf(c.gpa, job, i, under, angle, &c.lists[k]);
        }
    };
    const c: Pass = .{ .pj = pj, .items = items.items, .lists = lists, .gpa = b.gpa, .b = b };
    zs.parallel.forEach(pj.threads, items.items.len, &c, Pass.run) catch |e| return @as(Allocator.Error, @errorCast(e));
    if (b.canceled()) return;
    var hits: std.ArrayList(Hang) = .empty;
    defer hits.deinit(b.gpa);
    // Each part at its place, on the level of its layer.
    for (pj.instances) |inst| for (items.items, lists) |it, l| {
        if (it.group != inst.group) continue;
        const g = &pj.groups[inst.group];
        for (l.items) |h| {
            var q = h;
            q.layer = g.layer_level[h.layer];
            q.x += geom.toMm(inst.dx);
            q.y += geom.toMm(inst.dy);
            try hits.append(b.gpa, q);
        }
    };

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
            // A bridge of less than 2 mm prints well in any case.
            if (hh.span < 2) continue;
            if (s.project.bridges) {
                try b.add(.{ .kind = .bridge, .severity = if (hh.span > 15) 1 else 0, .layer = hh.layer, .path = Issue.no_path, .x = hh.x, .y = hh.y, .value = hh.span, .text_start = 0, .text_len = 0 }, "Layer {d}: a bridge of about {d:.1} mm over air ({d:.1} mm²). It prints as a bridge (project.bridges): straight lines across, anchored at both ends, slow, with the fan on.{s}", .{ hh.layer + 1, hh.span, hh.area, if (hh.span > 15) " A bridge this long can still sag: add support under it, or turn the part." else "" });
            } else {
                try b.add(.{ .kind = .bridge, .severity = if (hh.span > 15) 2 else 1, .layer = hh.layer, .path = Issue.no_path, .x = hh.x, .y = hh.y, .value = hh.span, .text_start = 0, .text_len = 0 }, "Layer {d}: a bridge of about {d:.1} mm over air ({d:.1} mm²), printed as normal skin. Turn on project.bridges: it prints the bridge across the air, slow, with the fan on.", .{ hh.layer + 1, hh.span, hh.area });
            }
        } else {
            try b.add(.{ .kind = .overhang, .severity = if (hh.area > 10) 2 else 1, .layer = hh.layer, .path = Issue.no_path, .x = hh.x, .y = hh.y, .value = hh.area, .text_start = 0, .text_len = 0 }, "Layer {d}: {d:.1} mm² hang out past the layer below, flatter than {d:.0}° (project.support_angle), with support off. It can sag or curl. Turn on support, or add support there (right click).", .{ hh.layer + 1, hh.area, s.project.support_angle });
        }
    }
}

fn islandIssues(b: *Builder, job: *const zs.PlateJob) Allocator.Error!void {
    for (job.islands[0..@min(job.islands.len, max_per_kind)]) |isl| {
        try b.add(.{ .kind = .island, .severity = 2, .layer = @intCast(isl.layer), .path = Issue.no_path, .x = isl.x, .y = isl.y, .value = isl.area, .text_start = 0, .text_len = 0 }, "Layer {d}: a shape of {d:.1} mm² starts in the air, with nothing under it. Add support there, or turn the part.", .{ isl.layer + 1, isl.area });
    }
}

/// The regions of a filament of a painted part narrower than a line (see
/// `Kind.color`): the smallest first, one for each layer at most.
fn colorIssues(b: *Builder, job: *const zs.PlateJob) Allocator.Error!void {
    const Tiny = struct { layer: u32, x: f64, y: f64, area: f64, filament: u32 };
    var list: std.ArrayList(Tiny) = .empty;
    defer list.deinit(b.gpa);
    for (job.groups) |*g| {
        if (!g.painted) continue;
        const r = g.job.resolved;
        const w = geom.fromMm(r.line_width);
        const filament = r.settings.project.filament;
        for (g.job.outlines, 0..) |o, l| {
            if (o.isEmpty()) continue;
            // Less than a line across: an opening by half a line leaves
            // nothing of it.
            for (0..o.count()) |k| {
                const poly = o.get(k);
                const area = geom.areaMm2(poly);
                if (!(area > 0) or area > 4 * r.line_width * r.line_width * 4) continue;
                var one: geom.Paths = .empty;
                defer one.deinit(b.gpa);
                try one.append(b.gpa, poly);
                var open = try zs.offset.opening(b.gpa, one, @divTrunc(w, 2), .{});
                defer open.deinit(b.gpa);
                if (!open.isEmpty()) continue;
                const p = poly[0];
                try list.append(b.gpa, .{ .layer = g.layer_level[l], .x = geom.toMm(p.x), .y = geom.toMm(p.y), .area = area, .filament = filament });
                break;
            }
        }
    }
    std.mem.sort(Tiny, list.items, {}, struct {
        fn lt(_: void, x: Tiny, y: Tiny) bool {
            return x.area < y.area;
        }
    }.lt);
    for (list.items[0..@min(list.items.len, 20)]) |ti| {
        try b.add(.{ .kind = .color, .severity = 1, .layer = ti.layer, .path = Issue.no_path, .x = ti.x, .y = ti.y, .value = ti.area, .text_start = 0, .text_len = 0 }, "Layer {d}: a region of filament {d} of {d:.2} mm² is narrower than a line. It prints as a blob, or not at all. Paint a larger area, or paint less near the edge.", .{ ti.layer + 1, ti.filament, ti.area });
    }
}

/// The filament changes of the print (see `Kind.changes`), and the place
/// of the prime tower (`Kind.tower`).
/// A part (or the painted region of one) that prints with a nozzle of a
/// printer with two, past the reach of that nozzle: the second nozzle left
/// of machine.nozzle2_min_x or above nozzle2_max_height, the first right
/// of nozzle1_max_x or above nozzle1_max_height. One issue for each part,
/// nozzle, and limit.
fn reachIssues(b: *Builder, pj: *const zs.PlateJob, s: zs.Settings) Allocator.Error!void {
    const m = s.machine;
    if (m.nozzles < 2 or pj.slots.len < 1) return;
    for (pj.instances) |inst| {
        const g = &pj.groups[inst.group];
        // For each nozzle: the least x, the most x, the top, and a place.
        var low = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        var high = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
        var top = [2]f64{ 0, 0 };
        var at = [2][3]f64{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
        for (g.job.outlines, 0..) |o, i| {
            if (o.isEmpty()) continue;
            const t = pj.toolAt(inst.group, i);
            const f = if (t < pj.slots.len) pj.slots[t] else s.filament;
            const nz: usize = @min(f.nozzle, 1);
            const box = o.bounds();
            const x0 = geom.toMm(box.min.x + inst.dx);
            const x1 = geom.toMm(box.max.x + inst.dx);
            const y = geom.toMm(@divTrunc(box.min.y + box.max.y, 2) + inst.dy);
            const lv: f64 = @floatFromInt(g.layer_level[i]);
            if (x0 < low[nz]) {
                low[nz] = x0;
                if (nz == 1) at[1] = .{ x0, y, lv };
            }
            if (x1 > high[nz]) {
                high[nz] = x1;
                if (nz == 0) at[0] = .{ x1, y, lv };
            }
            top[nz] = @max(top[nz], g.job.layers[i].z);
        }
        if (high[0] > -std.math.inf(f64)) {
            if (m.nozzle1_max_x > 0 and high[0] > m.nozzle1_max_x + 0.05)
                try b.add(.{ .kind = .reach, .severity = 2, .layer = @intFromFloat(at[0][2]), .path = Issue.no_path, .x = at[0][0], .y = at[0][1], .value = high[0], .text_start = 0, .text_len = 0 }, "A part on the first nozzle reaches x = {d:.1} mm, but the first nozzle stops at x = {d:.1} mm (machine.nozzle1_max_x). Move the part left, or give it a filament of the second nozzle.", .{ high[0], m.nozzle1_max_x });
            if (m.nozzle1_max_height > 0 and top[0] > m.nozzle1_max_height + 0.05)
                try b.add(.{ .kind = .reach, .severity = 2, .layer = 0, .path = Issue.no_path, .x = at[0][0], .y = at[0][1], .value = top[0], .text_start = 0, .text_len = 0 }, "A part on the first nozzle is {d:.1} mm high, but the first nozzle reaches only {d:.1} mm (machine.nozzle1_max_height). Give its top layers a filament of the second nozzle.", .{ top[0], m.nozzle1_max_height });
        }
        if (low[1] < std.math.inf(f64)) {
            if (m.nozzle2_min_x > 0 and low[1] < m.nozzle2_min_x - 0.05)
                try b.add(.{ .kind = .reach, .severity = 2, .layer = @intFromFloat(at[1][2]), .path = Issue.no_path, .x = at[1][0], .y = at[1][1], .value = low[1], .text_start = 0, .text_len = 0 }, "A part on the second nozzle reaches x = {d:.1} mm, but the second nozzle stops at x = {d:.1} mm (machine.nozzle2_min_x). Move the part right, or give it a filament of the main nozzle.", .{ low[1], m.nozzle2_min_x });
            if (m.nozzle2_max_height > 0 and top[1] > m.nozzle2_max_height + 0.05)
                try b.add(.{ .kind = .reach, .severity = 2, .layer = 0, .path = Issue.no_path, .x = at[1][0], .y = at[1][1], .value = top[1], .text_start = 0, .text_len = 0 }, "A part on the second nozzle is {d:.1} mm high, but the second nozzle reaches only {d:.1} mm (machine.nozzle2_max_height). Give its top layers a filament of the main nozzle.", .{ top[1], m.nozzle2_max_height });
        }
    }
}

fn changeIssues(b: *Builder, job: *const zs.PlateJob, s: zs.Settings, stats: zs.Stats) Allocator.Error!void {
    const m = s.machine;
    if (stats.changes > 0) {
        const time = @as(f64, @floatFromInt(stats.changes)) * m.change_time;
        const share = if (stats.print_time_s > 0) time / stats.print_time_s else 0;
        if (m.filament_change == .pause) {
            try b.add(.{ .kind = .changes, .severity = if (stats.changes > 10) 2 else 1, .layer = 0, .path = Issue.no_path, .x = 0, .y = 0, .value = @floatFromInt(stats.changes), .text_start = 0, .text_len = 0 }, "The print pauses {d} times for a filament change, and each pause waits for you. A printer with a unit that feeds many filaments changes them by itself: set machine.filament_change to tool.", .{stats.changes});
        } else if (share > 0.3 or stats.changes > 200) {
            try b.add(.{ .kind = .changes, .severity = 1, .layer = 0, .path = Issue.no_path, .x = 0, .y = 0, .value = @floatFromInt(stats.changes), .text_start = 0, .text_len = 0 }, "The print has {d} filament changes: about {d:.0} min, {d:.0} % of the print time. Fewer colors on the layers of many changes, or paint by layers, makes it shorter.", .{ stats.changes, time / 60, share * 100 });
        } else {
            try b.add(.{ .kind = .changes, .severity = 0, .layer = 0, .path = Issue.no_path, .x = 0, .y = 0, .value = @floatFromInt(stats.changes), .text_start = 0, .text_len = 0 }, "The print has {d} filament changes (about {d:.0} min).", .{ stats.changes, time / 60 });
        }
    }
    const t = job.tower() orelse return;
    const h = t.size / 2;
    var bad = t.x - h < 0 or t.y - h < 0 or t.x + h > m.bed_size_x or t.y + h > m.bed_size_y;
    if (job.bounds()) |pb| {
        // The parts are in bed coordinates: their box and the tower must
        // not touch.
        if (!(t.x + h < pb[0] or t.x - h > pb[2] or t.y + h < pb[1] or t.y - h > pb[3])) bad = true;
    }
    if (bad) try b.add(.{ .kind = .tower, .severity = 2, .layer = 0, .path = Issue.no_path, .x = t.x, .y = t.y, .value = t.size, .text_start = 0, .text_len = 0 }, "The prime tower at {d:.0}, {d:.0} mm is off the bed or on a part. Move the parts, or set project.prime_tower_x and project.prime_tower_y.", .{ t.x, t.y });
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
        try b.add(.{ .kind = .retractions, .severity = 0, .layer = @intCast(l), .path = Issue.no_path, .x = c[0], .y = c[1], .value = @floatFromInt(count), .text_start = 0, .text_len = 0 }, "Layer {d} has {d} retractions. Many retractions grind the filament at one place of the feeder. Combing (project.combing) keeps more travels inside the part.", .{ l + 1, count });
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

test "checks: the brim holds a thin pin, and a box has no note" {
    const gpa = std.testing.allocator;
    // A pin of 4 x 4 x 40 mm with an 8 mm brim, and a box of 20 mm.
    for ([_]struct { box: [6]f64, notes: usize }{
        .{ .box = .{ 0, 0, 0, 4, 4, 40 }, .notes = 1 },
        .{ .box = .{ 0, 0, 0, 20, 20, 20 }, .notes = 0 },
    }) |c| {
        var b: zs.mesh.Builder = .init(gpa);
        const x = c.box;
        try zs.mesh.shapes.addBox(&b, x[0], x[1], x[2], x[3], x[4], x[5]);
        var mesh = try b.finish();
        defer mesh.deinit(gpa);
        var stl: std.Io.Writer.Allocating = .init(gpa);
        defer stl.deinit();
        try mesh.writeStl(&stl.writer);
        const app = try zs.app.App.create(gpa, null, null);
        defer app.destroy();
        try app.setSetting("project.brim_width", "8");
        try app.loadStl("part.stl", stl.written());
        try app.startSlice();
        app.stopWorkerForTest();
        const r = try app.checks();
        var notes: usize = 0;
        for (r.issues) |i| if (i.kind == .stand) {
            notes += 1;
            try std.testing.expectEqual(@as(u8, 0), i.severity);
            try std.testing.expect(std.mem.indexOf(u8, r.textOf(i), "the brim holds this part") != null);
        };
        try std.testing.expectEqual(c.notes, notes);
    }
}

test "checks: a painted letter rests on the base of the other filament" {
    const gpa = std.testing.allocator;
    // A base and a letter on it; the letter has filament 2. Each filament
    // is its own job, but the base holds the letter up: no overhang.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 30, 20, 3);
    try zs.mesh.shapes.addBox(&b, 12, 7, 3, 18, 13, 5);
    var mesh = try b.finish();
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const nf = mesh.faces.items.len;
    mesh.deinit(gpa);
    const app = try zs.app.App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("plaque.stl", stl.written());
    _ = try @import("filament_slots.zig").add(app);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (nf - 12..nf) |t| try text.writer.print("{d} 8\n", .{t});
    try app.setPartPaint(0, text.written());
    try app.startSlice();
    app.stopWorkerForTest();
    const r = try app.checks();
    for (r.issues) |i| try std.testing.expect(i.kind != .overhang and i.kind != .bridge);
}

test "checks: a part on the second nozzle past its reach" {
    const gpa = std.testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 10, 10, 5);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try zs.app.App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("box.stl", stl.written());
    try app.setSetting("machine.nozzles", "2");
    try app.setSetting("machine.nozzle2_min_x", "20.5");
    try app.setSetting("machine.filament_change", "tool");
    const slots = @import("filament_slots.zig");
    _ = try slots.add(app);
    try slots.set(app, 1, "filament.nozzle", "1");
    try app.setPartSetting(0, "project.filament", "2");
    // The box at the left edge of the bed: x from 1 to 11.
    try app.movePart(0, 6, 100);
    try app.startSlice();
    app.stopWorkerForTest();
    var r = try app.checks();
    var reach: usize = 0;
    for (r.issues) |i| reach += @intFromBool(i.kind == .reach);
    try std.testing.expectEqual(@as(usize, 1), reach);
    // In reach: no issue.
    try app.movePart(0, 100, 100);
    try app.startSlice();
    app.stopWorkerForTest();
    r = try app.checks();
    for (r.issues) |i| try std.testing.expect(i.kind != .reach);
}
