//! Refinements: the first slice is a guide, and the user refines it.
//! This file finds the refinements of a project, and keeps them in a
//! store of the app. It finds the refinements that the user makes again
//! and again, and offers them on the next print.
//!
//! - **The guide:** the facts of the first step of the history with a part
//!   on the plate (see history.zig).
//! - **The refinements of a project:** the changes from the guide to the
//!   facts now, for the print, a part, some layers, a line, or an area.
//!   The records leave out the choice of a printer or a material, and
//!   a move or a turn of a part. An undo removes a refinement.
//! - **A record:** one refinement with its context, on one line:
//!   "kind\tzone\tkey\told\tnew\tmaterial\tprinter\tnozzle\tz_lo\tz_hi".
//!   The zone of some layers is "bottom" (from the bed), "top" (to the
//!   top of the part), or "middle"; else it is "-".
//! - **The store:** the records of the projects of the app, each line
//!   "project\trecord". The app keeps it (a file, local storage); it stays
//!   on the device. `merge` replaces the records of one project.
//! - **Suggestions:** the same refinement (kind, zone, key) with the same
//!   material and nozzle in at least two other projects, and not in the
//!   project now. The value is the most frequent one. A suggestion line:
//!   "kind\tzone\tkey\tvalue\tcount\tz_lo\tz_hi". `apply` makes it a
//!   change of the app.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const history = @import("history.zig");
const zs = @import("../root.zig");

/// The context of the records of a project.
pub const Context = struct {
    material: []const u8,
    printer: []const u8,
    nozzle: f64,
    /// The height of the parts (mm): the top z of the last slice.
    height: f64,
};

/// The most lines that the store keeps; the oldest projects go first.
pub const max_store_lines = 4000;
/// Layers that start this close to the bed are "bottom" (mm).
const bottom_mm = 1.0;
/// Layers that end this close to the top are "top" (mm).
const top_mm = 0.5;

/// The facts of the guide: the first step with a part on the plate.
pub fn guideFacts(h: *const history.History) ?[]const u8 {
    for (h.steps.items[0 .. @min(h.current, h.steps.items.len -| 1) + 1]) |s| {
        if (std.mem.indexOf(u8, s.facts, "\t(part)\tyes") != null) return s.facts;
    }
    return null;
}

fn kindOf(scope: []const u8, key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, scope, "print")) {
        if (std.mem.eql(u8, key, "quality")) return null;
        return "print";
    }
    if (std.mem.startsWith(u8, scope, "part:")) {
        if (std.mem.indexOfScalar(u8, key, '.') == null) return null; // position, rotation, (part)
        return "part";
    }
    if (std.mem.startsWith(u8, scope, "layers:")) {
        if (std.mem.eql(u8, key, "(name)")) return null;
        return "layers";
    }
    if (std.mem.eql(u8, scope, "edits")) return "line";
    if (std.mem.startsWith(u8, scope, "areas") or std.mem.startsWith(u8, scope, "area")) return "area";
    return null;
}

fn zoneOf(lo: f64, hi: f64, height: f64) []const u8 {
    if (lo <= bottom_mm) return "bottom";
    if (height > 0 and hi >= height - top_mm) return "top";
    return "middle";
}

/// Writes the records of the refinements from the facts `guide` to the
/// facts `now`.
pub fn records(gpa: Allocator, guide: []const u8, now: []const u8, ctx: Context, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dw: std.Io.Writer.Allocating = .init(a);
    try history.diff(a, guide, now, &dw.writer);
    const changes = try history.parseChanges(a, dw.written());
    for (changes) |c| {
        const kind = kindOf(c.scope, c.key) orelse continue;
        if (c.new.len == 0 and !std.mem.eql(u8, kind, "line") and !std.mem.eql(u8, kind, "area")) continue; // a refinement undone
        var zone: []const u8 = "-";
        var lo: f64 = 0;
        var hi: f64 = 0;
        if (history.layerRange(c.scope)) |r| {
            lo = r[0];
            hi = @min(r[1], if (ctx.height > 0) ctx.height else r[1]);
            zone = zoneOf(lo, hi, ctx.height);
        }
        try w.print("{s}\t{s}\t", .{ kind, zone });
        try history.writeEscaped(w, c.key);
        try w.writeByte('\t');
        try history.writeEscaped(w, c.old);
        try w.writeByte('\t');
        try history.writeEscaped(w, c.new);
        try w.print("\t{s}\t{s}\t{d}\t{d:.3}\t{d:.3}\n", .{ ctx.material, ctx.printer, ctx.nozzle, lo, hi });
    }
}

/// The store with the records of `project` replaced by `recs`. The newest
/// project goes last; the oldest lines go past `max_store_lines`.
pub fn merge(gpa: Allocator, store: []const u8, project: []const u8, recs: []const u8, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(gpa);
    var it = std.mem.splitScalar(u8, store, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], project)) continue;
        try keep.append(gpa, line);
    }
    var new_count: usize = 0;
    var rit = std.mem.splitScalar(u8, recs, '\n');
    while (rit.next()) |r| {
        if (r.len > 0) new_count += 1;
    }
    const room = max_store_lines -| new_count;
    const skip = keep.items.len -| room;
    for (keep.items[skip..]) |line| try w.print("{s}\n", .{line});
    rit = std.mem.splitScalar(u8, recs, '\n');
    while (rit.next()) |r| {
        if (r.len > 0) try w.print("{s}\t{s}\n", .{ project, r });
    }
}

const Rec = struct {
    project: []const u8,
    kind: []const u8,
    zone: []const u8,
    key: []const u8,
    new: []const u8,
    material: []const u8,
    nozzle: f64,
    lo: f64,
    hi: f64,
};

fn parseRec(line: []const u8) ?Rec {
    var f: [11][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, '\t');
    for (&f) |*x| x.* = it.next() orelse return null;
    return .{
        .project = f[0],
        .kind = f[1],
        .zone = f[2],
        .key = f[3],
        .new = f[5],
        .material = f[6],
        .nozzle = std.fmt.parseFloat(f64, f[8]) catch return null,
        .lo = std.fmt.parseFloat(f64, f[9]) catch 0,
        .hi = std.fmt.parseFloat(f64, f[10]) catch 0,
    };
}

/// The value of `key` in the facts now, for a suggestion of its kind and
/// zone: true if the project has it already.
fn hasNow(now: []const u8, kind: []const u8, zone: []const u8, key: []const u8, value: []const u8, height: f64) bool {
    var it = std.mem.splitScalar(u8, now, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const scope = f.next() orelse continue;
        const k = f.next() orelse continue;
        const v = f.next() orelse continue;
        if (!std.mem.eql(u8, k, key)) continue;
        const sk = kindOf(scope, k) orelse continue;
        if (!std.mem.eql(u8, sk, kind)) continue;
        if (history.layerRange(scope)) |r| {
            if (!std.mem.eql(u8, zoneOf(r[0], @min(r[1], if (height > 0) height else r[1]), height), zone)) continue;
        }
        if (std.mem.eql(u8, kind, "layers")) return true; // a value for the zone is there already
        if (std.mem.eql(u8, v, value)) return true;
    }
    return false;
}

/// Writes the suggestions for the project `project` with the facts `now`.
/// Only refinements of the print, of parts, and of the bottom or top
/// layers: a line, an area, or the middle layers belong to one shape.
pub fn suggest(gpa: Allocator, store: []const u8, project: []const u8, now: []const u8, ctx: Context, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Group = struct {
        kind: []const u8,
        zone: []const u8,
        key: []const u8,
        projects: std.StringArrayHashMapUnmanaged(void) = .empty,
        values: std.StringArrayHashMapUnmanaged(u32) = .empty,
        last_value: []const u8 = "",
        spans: std.ArrayList(f64) = .empty,
    };
    var groups: std.StringArrayHashMapUnmanaged(Group) = .empty;
    var it = std.mem.splitScalar(u8, store, '\n');
    while (it.next()) |line| {
        const r = parseRec(line) orelse continue;
        if (std.mem.eql(u8, r.project, project)) continue;
        if (!std.ascii.eqlIgnoreCase(r.material, ctx.material)) continue;
        if (@abs(r.nozzle - ctx.nozzle) > 0.01) continue;
        const usable = std.mem.eql(u8, r.kind, "print") or std.mem.eql(u8, r.kind, "part") or
            (std.mem.eql(u8, r.kind, "layers") and (std.mem.eql(u8, r.zone, "bottom") or std.mem.eql(u8, r.zone, "top")));
        if (!usable) continue;
        const gk = try std.fmt.allocPrint(a, "{s}\t{s}\t{s}", .{ r.kind, r.zone, r.key });
        const g = try groups.getOrPut(a, gk);
        if (!g.found_existing) g.value_ptr.* = .{ .kind = r.kind, .zone = r.zone, .key = r.key };
        const gr = g.value_ptr;
        try gr.projects.put(a, r.project, {});
        const vc = try gr.values.getOrPut(a, r.new);
        if (!vc.found_existing) vc.value_ptr.* = 0;
        vc.value_ptr.* += 1;
        gr.last_value = r.new;
        // The span of the layers: from the bed for "bottom", from the top
        // for "top".
        if (std.mem.eql(u8, r.zone, "bottom")) try gr.spans.append(a, r.hi);
        if (std.mem.eql(u8, r.zone, "top")) try gr.spans.append(a, r.hi - r.lo);
    }
    for (groups.values()) |*g| {
        if (g.projects.count() < 2) continue;
        // The most frequent value; the last one on a tie.
        var best = g.last_value;
        var best_n: u32 = g.values.get(best) orelse 0;
        var vit = g.values.iterator();
        while (vit.next()) |e| if (e.value_ptr.* > best_n) {
            best = e.key_ptr.*;
            best_n = e.value_ptr.*;
        };
        if (hasNow(now, g.kind, g.zone, g.key, best, ctx.height)) continue;
        var lo: f64 = 0;
        var hi: f64 = 0;
        if (g.spans.items.len > 0) {
            std.mem.sort(f64, g.spans.items, {}, std.sort.asc(f64));
            const span = g.spans.items[g.spans.items.len / 2];
            if (std.mem.eql(u8, g.zone, "bottom")) {
                lo = -zs.settings.part_z;
                hi = span;
            } else {
                hi = zs.settings.part_z;
                lo = if (ctx.height > 0) ctx.height - span else 0;
                if (ctx.height <= 0) continue; // no top before a slice
            }
        }
        try w.print("{s}\t{s}\t", .{ g.kind, g.zone });
        try history.writeEscaped(w, g.key);
        try w.writeByte('\t');
        try history.writeEscaped(w, best);
        try w.print("\t{d}\t{d:.3}\t{d:.3}\n", .{ g.projects.count(), lo, hi });
    }
}

/// One suggestion line, parsed.
pub const Suggestion = struct {
    kind: []const u8,
    zone: []const u8,
    key: []const u8,
    value: []const u8,
    count: u32,
    lo: f64,
    hi: f64,

    pub fn parse(line: []const u8) ?Suggestion {
        var f: [7][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\n"), '\t');
        for (&f) |*x| x.* = it.next() orelse return null;
        return .{
            .kind = f[0],
            .zone = f[1],
            .key = f[2],
            .value = f[3],
            .count = std.fmt.parseInt(u32, f[4], 10) catch return null,
            .lo = std.fmt.parseFloat(f64, f[5]) catch return null,
            .hi = std.fmt.parseFloat(f64, f[6]) catch return null,
        };
    }
};

const testing = std.testing;

const ctx_pla: Context = .{ .material = "PLA", .printer = "TAZ", .nozzle = 0.4, .height = 48 };

test "refine: the records of a project are its changes from the guide" {
    const guide = "print\tproject.infill_density\t0.2\npart:Benchy\t(part)\tyes\npart:Benchy\tposition\t10, 20\n";
    const now = "print\tproject.infill_density\t0.2\nprint\tproject.outer_wall_speed\t25\n" ++
        "part:Benchy\t(part)\tyes\npart:Benchy\tposition\t40, 20\npart:Benchy\tproject.wall_count\t4\n" ++
        "layers:0.0000:0.6000\tproject.fan_speed\t0\n";
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try records(testing.allocator, guide, now, ctx_pla, &w.writer);
    try testing.expectEqualStrings(
        "print\t-\tproject.outer_wall_speed\t\t25\tPLA\tTAZ\t0.4\t0.000\t0.000\n" ++
            "part\t-\tproject.wall_count\t\t4\tPLA\tTAZ\t0.4\t0.000\t0.000\n" ++
            "layers\tbottom\tproject.fan_speed\t\t0\tPLA\tTAZ\t0.4\t0.000\t0.600\n",
        w.written(),
    );
}

test "refine: a refinement made in two projects is a suggestion in a third" {
    const gpa = testing.allocator;
    const rec = "print\t-\tproject.outer_wall_speed\t\t25\tPLA\tTAZ\t0.4\t0.000\t0.000\n" ++
        "layers\ttop\tproject.fan_speed\t\t1\tPLA\tTAZ\t0.4\t40.000\t48.000\n";
    var s1: std.Io.Writer.Allocating = .init(gpa);
    defer s1.deinit();
    try merge(gpa, "", "p1", rec, &s1.writer);
    var s2: std.Io.Writer.Allocating = .init(gpa);
    defer s2.deinit();
    try merge(gpa, s1.written(), "p2", rec, &s2.writer);
    // The same project again replaces its lines.
    var s3: std.Io.Writer.Allocating = .init(gpa);
    defer s3.deinit();
    try merge(gpa, s2.written(), "p2", rec, &s3.writer);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, s3.written(), "\n"));

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const now = "part:Boat\t(part)\tyes\n";
    try suggest(gpa, s3.written(), "p3", now, .{ .material = "pla", .printer = "TAZ", .nozzle = 0.4, .height = 30 }, &out.writer);
    try testing.expectEqualStrings(
        "print\t-\tproject.outer_wall_speed\t25\t2\t0.000\t0.000\n" ++
            "layers\ttop\tproject.fan_speed\t1\t2\t22.000\t100000.000\n",
        out.written(),
    );
    const sg = Suggestion.parse("layers\ttop\tproject.fan_speed\t1\t2\t22.000\t100000.000\n").?;
    try testing.expectEqualStrings("project.fan_speed", sg.key);
    try testing.expectEqual(@as(f64, 22), sg.lo);

    // Another material, or a project with the value already: no suggestion.
    var none: std.Io.Writer.Allocating = .init(gpa);
    defer none.deinit();
    try suggest(gpa, s3.written(), "p3", now, .{ .material = "PETG", .printer = "TAZ", .nozzle = 0.4, .height = 30 }, &none.writer);
    try suggest(gpa, s3.written(), "p1", now, ctx_pla, &none.writer);
    try testing.expectEqualStrings("", none.written());
    var have: std.Io.Writer.Allocating = .init(gpa);
    defer have.deinit();
    try suggest(gpa, s3.written(), "p3", "print\tproject.outer_wall_speed\t25\nlayers:20.0000:100000.0000\tproject.fan_speed\t1\n", .{ .material = "PLA", .printer = "TAZ", .nozzle = 0.4, .height = 30 }, &have.writer);
    try testing.expectEqualStrings("", have.written());
}
