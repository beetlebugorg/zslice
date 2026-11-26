//! The move stream of a layer: the stored form of its print.
//!
//! A stream is a flat copy of a layer plan in one block of memory, with
//! no pointer to a job:
//!
//! - The paths in print order. Each path has its feature, its width, its
//!   height, and the number of its region.
//! - The points of the paths, as two 32-bit integers for each point, and
//!   the length of the move to each point.
//! - The travel to each path: the combing way, or a retraction, and the
//!   answers of the layer outline that the travel needs (see
//!   gcode.Prepared).
//! - The regions. A region is a reference to settings: a part of the
//!   plate and a modifier volume. The stream has no setting value.
//! - On a layer of many filaments, the rank of each path (see
//!   LayerPlan.rank).
//!
//! The emitter makes the speeds, the flow, the fan, the temperatures, and
//! the times from the stream and the settings of the job (see gcode.zig).
//! So a change of a setting that changes no path (see
//! settings.isPatchSetting) needs no new plan: the next slice binds each
//! stream to its new settings, then runs, links, and writes the text.
//!
//! A stream holds the travel answers for one start position of the
//! layer. A run from another position asks the outline, and a stream has
//! none: then the pipeline plans the layer again (see engine.zig).
//!
//! Memory: 16 bytes for each point and 64 bytes for each path.

const std = @import("std");
const type_fields = @import("type_fields.zig");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const gcode = @import("gcode.zig");
const layer_mod = @import("layer.zig");
const settings_mod = @import("settings.zig");
const LayerPlan = layer_mod.LayerPlan;
const Path = layer_mod.Path;
const PointZ = layer_mod.PointZ;
const PathPrep = gcode.Prepared.PathPrep;
const Resolved = settings_mod.Resolved;

/// Gives a plan from a stream its settings: `lp.resolved`, and the
/// settings of each region in `regions`. `lp` has its part and its region
/// lists.
pub const BindFn = *const fn (ctx: *const anyopaque, i: usize, lp: *LayerPlan, regions: []*const Resolved) void;

pub const Stream = struct {
    valid: bool = false,
    mem: []align(8) u8 = &.{},
    head: Head = .{},

    const Head = struct {
        index: u32 = 0,
        part: u32 = 0,
        z: f64 = 0,
        height: f64 = 0,
        width: f64 = 0,
        end: ?[2]f64 = null,
        end_feature: ?settings_mod.Feature = null,
        paths: u32 = 0,
        points: u32 = 0,
        ways: u32 = 0,
        point_w: u32 = 0,
        point_z: u32 = 0,
        regions: u32 = 0,
        region_part: u32 = 0,
        region_layer: u32 = 0,
        rank: u32 = 0,
    };

    /// The lists of a stream in its block, in the order of their
    /// alignment.
    const Lists = struct {
        lengths: []f64,
        ways: [][2]f64,
        preps: []PathPrep,
        points: [][2]i32,
        paths: []Path,
        ends: []u32,
        point_w: []f32,
        point_z: []PointZ,
        region_part: []u32,
        region_layer: []u32,
        region_modifier: []u16,
        rank: []u32,
    };

    fn size(h: Head) usize {
        var n: usize = 0;
        inline for (type_fields.structFields(Lists)) |f| {
            const T = @typeInfo(f.type).pointer.child;
            n = std.mem.alignForward(usize, n, @alignOf(T)) + @sizeOf(T) * count(h, f.name);
        }
        return n;
    }

    fn count(h: Head, comptime name: []const u8) usize {
        const eq = std.mem.eql;
        if (comptime eq(u8, name, "lengths") or eq(u8, name, "points")) return h.points;
        if (comptime eq(u8, name, "preps") or eq(u8, name, "paths") or eq(u8, name, "ends")) return h.paths;
        if (comptime eq(u8, name, "region_modifier")) return h.regions;
        return @field(h, name);
    }

    fn lists(s: *const Stream) Lists {
        var out: Lists = undefined;
        var n: usize = 0;
        inline for (type_fields.structFields(Lists)) |f| {
            const T = @typeInfo(f.type).pointer.child;
            n = std.mem.alignForward(usize, n, @alignOf(T));
            const len = count(s.head, f.name);
            const raw = s.mem[n..][0 .. @sizeOf(T) * len];
            @field(out, f.name) = @alignCast(std.mem.bytesAsSlice(T, raw));
            n += raw.len;
        }
        return out;
    }

    pub fn deinit(s: *Stream, gpa: Allocator) void {
        gpa.free(s.mem);
        s.* = .{};
    }

    /// The bytes of the stream.
    pub fn bytes(s: *const Stream) usize {
        return s.mem.len;
    }

    /// The stream of `lp` and its travel answers `prep`, after a run of
    /// the layer. Not valid if the plan does not fit a stream, or if
    /// `bind` does not give the settings of the plan.
    pub fn encode(gpa: Allocator, lp: *const LayerPlan, prep: *const gcode.Prepared, bind: BindFn, ctx: *const anyopaque, i: usize) Allocator.Error!Stream {
        const pts = lp.points.points.items;
        const n_paths = lp.paths.items.len;
        if (lp.points.ends.items.len != n_paths or prep.paths.items.len != n_paths or prep.lengths.items.len != pts.len) return .{};
        if (lp.region_modifier.len != lp.region_resolved.len) return .{};
        if (lp.rank.len != 0 and lp.rank.len != n_paths) return .{};
        const lim = std.math.maxInt(i32);
        for (pts) |q| if (q.x > lim or q.x < -lim or q.y > lim or q.y < -lim) return .{};
        // The settings that `bind` gives must be the settings of the plan.
        {
            var view = lp.*;
            view.resolved = null;
            var buf: [64]*const Resolved = undefined;
            if (lp.region_resolved.len > buf.len) return .{};
            const got = buf[0..lp.region_resolved.len];
            bind(ctx, i, &view, got);
            if (view.resolved != lp.resolved) return .{};
            for (got, lp.region_resolved) |a, b| if (a != b) return .{};
        }
        var s: Stream = .{ .valid = true, .head = .{
            .index = lp.index,
            .part = lp.part,
            .z = lp.z,
            .height = lp.height,
            .width = lp.width,
            .end = prep.end,
            .end_feature = prep.end_feature,
            .paths = @intCast(n_paths),
            .points = @intCast(pts.len),
            .ways = @intCast(prep.way_points.items.len),
            .point_w = @intCast(lp.point_w.items.len),
            .point_z = @intCast(lp.point_z.items.len),
            .regions = @intCast(lp.region_modifier.len),
            .region_part = @intCast(lp.region_part.len),
            .region_layer = @intCast(lp.region_layer.len),
            .rank = @intCast(lp.rank.len),
        } };
        s.mem = try gpa.alignedAlloc(u8, .@"8", size(s.head));
        const l = s.lists();
        @memcpy(l.lengths, prep.lengths.items);
        @memcpy(l.ways, prep.way_points.items);
        @memcpy(l.preps, prep.paths.items);
        for (l.points, pts) |*d, q| d.* = .{ @intCast(q.x), @intCast(q.y) };
        @memcpy(l.paths, lp.paths.items);
        @memcpy(l.ends, lp.points.ends.items);
        @memcpy(l.point_w, lp.point_w.items);
        @memcpy(l.point_z, lp.point_z.items);
        @memcpy(l.region_part, lp.region_part);
        @memcpy(l.region_layer, lp.region_layer);
        @memcpy(l.region_modifier, lp.region_modifier);
        @memcpy(l.rank, lp.rank);
        return s;
    }

    /// A plan with the paths of the stream and no outline, and its travel
    /// answers in `prep`. The plan reads the lists of the stream: free it
    /// before the stream. Call `deinit` on the plan.
    pub fn decode(s: *const Stream, gpa: Allocator, prep: *gcode.Prepared, bind: BindFn, ctx: *const anyopaque, i: usize) Allocator.Error!LayerPlan {
        const h = s.head;
        const l = s.lists();
        var lp: LayerPlan = .{ .arena = .init(gpa), .index = h.index, .z = h.z, .height = h.height, .width = h.width, .part = h.part };
        errdefer lp.deinit();
        const a = lp.arena.allocator();
        const pts = try a.alloc(geom.Point, l.points.len);
        for (pts, l.points) |*d, q| d.* = .{ .x = q[0], .y = q[1] };
        lp.points = .{ .points = .{ .items = pts, .capacity = pts.len, .pointer_stability = .{} }, .ends = .{ .items = l.ends, .capacity = l.ends.len, .pointer_stability = .{} } };
        lp.paths = .{ .items = l.paths, .capacity = l.paths.len, .pointer_stability = .{} };
        lp.point_w = .{ .items = l.point_w, .capacity = l.point_w.len, .pointer_stability = .{} };
        lp.point_z = .{ .items = l.point_z, .capacity = l.point_z.len, .pointer_stability = .{} };
        lp.region_part = l.region_part;
        lp.region_layer = l.region_layer;
        lp.region_modifier = l.region_modifier;
        lp.rank = l.rank;
        const regions = try a.alloc(*const Resolved, h.regions);
        bind(ctx, i, &lp, regions);
        lp.region_resolved = regions;

        prep.clear();
        try prep.paths.appendSlice(gpa, l.preps);
        try prep.way_points.appendSlice(gpa, l.ways);
        try prep.lengths.appendSlice(gpa, l.lengths);
        prep.end = h.end;
        prep.end_feature = h.end_feature;
        prep.replay = true;
        return lp;
    }
};
