//! The toolpaths of a slice for the previews, in flat arrays of floats in
//! mm. `Toolpaths` has all layers, for the 3D view and the inspector.
//! `LayerPaths` has one layer, for a 2D view. The pick functions find the
//! path at a point, for a click in a view.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const feature_names = @import("feature_settings.zig").feature_names;

/// The paths of all layers of a slice, for a 3D view. The arrays are flat,
/// in mm, and in print order:
/// - path i has the points from path_ends[i - 1] to path_ends[i] (x, y
///   pairs in `points`), the feature path_features[i], the bead height
///   path_height[i], and is closed if path_closed[i] is 1;
/// - layer j has the paths from layer_ends[j - 1] to layer_ends[j], at the
///   height layer_z[j], with the layer height layer_height[j] and the line
///   width layer_width[j];
/// - a path whose nozzle height changes along it (slope smoothing) has
///   path_z_start[i] < no_z: its point k has the nozzle z
///   point_z[path_z_start[i] + k] and the bead area
///   point_area[path_z_start[i] + k]. The bead is under the nozzle, down
///   to the top of the layer below (layer_z - layer_height). A path whose
///   line width changes along it (Arachne walls) uses the same arrays,
///   with the z of its layer at each point.
pub const Toolpaths = struct {
    points: std.ArrayList(f32) = .empty,
    path_ends: std.ArrayList(u32) = .empty,
    path_features: std.ArrayList(u8) = .empty,
    path_closed: std.ArrayList(u8) = .empty,
    /// The cross-section area (mm^2) of the bead of each path.
    path_area: std.ArrayList(f32) = .empty,
    /// The bead height (mm) of each path: the layer height, or for
    /// combined infill the height of its layers (project.infill_layers).
    path_height: std.ArrayList(f32) = .empty,
    /// The print time (s) from the start to the start of the extrusion of
    /// each path, and to its end.
    path_start_time: std.ArrayList(f32) = .empty,
    path_end_time: std.ArrayList(f32) = .empty,
    /// 1 if the travel to the path retracted the filament.
    path_retract: std.ArrayList(u8) = .empty,
    /// The fan of each path, from 0 (off) to 255.
    path_fan: std.ArrayList(u8) = .empty,
    /// The modifier volume of each path: 0 for none, k + 1 for
    /// `Job.modifiers[k]` of the job of its part (see layer.Modifier).
    path_modifier: std.ArrayList(u16) = .empty,
    /// The part of the plate of each path (see plate_job.zig), or
    /// LayerPlan.no_part for the skirt and the brim around many parts.
    path_part: std.ArrayList(u32) = .empty,
    /// The nozzle lift of a retracted travel (project.z_hop), in mm.
    z_hop: f32 = 0,
    /// 1 if the layer prints slower than planned, to cool
    /// (filament.min_layer_time).
    layer_slowed: std.ArrayList(u8) = .empty,
    layer_ends: std.ArrayList(u32) = .empty,
    layer_z: std.ArrayList(f32) = .empty,
    layer_height: std.ArrayList(f32) = .empty,
    layer_width: std.ArrayList(f32) = .empty,
    path_z_start: std.ArrayList(u32) = .empty,
    point_z: std.ArrayList(f32) = .empty,
    /// The deposited bead area (mm²), with the flow ratio.
    point_area: std.ArrayList(f32) = .empty,
    gpa: ?Allocator = null,

    pub const no_z = std.math.maxInt(u32);

    pub fn deinit(t: *Toolpaths, gpa: Allocator) void {
        t.points.deinit(gpa);
        t.path_ends.deinit(gpa);
        t.path_features.deinit(gpa);
        t.path_closed.deinit(gpa);
        t.path_area.deinit(gpa);
        t.path_height.deinit(gpa);
        t.path_start_time.deinit(gpa);
        t.path_end_time.deinit(gpa);
        t.path_retract.deinit(gpa);
        t.path_fan.deinit(gpa);
        t.path_modifier.deinit(gpa);
        t.path_part.deinit(gpa);
        t.layer_slowed.deinit(gpa);
        t.layer_ends.deinit(gpa);
        t.layer_z.deinit(gpa);
        t.layer_height.deinit(gpa);
        t.layer_width.deinit(gpa);
        t.path_z_start.deinit(gpa);
        t.point_z.deinit(gpa);
        t.point_area.deinit(gpa);
        t.* = .{};
    }

    /// Empties the arrays, and keeps their memory.
    pub fn clearRetainingCapacity(t: *Toolpaths) void {
        inline for (@typeInfo(Toolpaths).@"struct".fields) |f| {
            if (@typeInfo(f.type) == .@"struct" and @hasDecl(f.type, "clearRetainingCapacity")) {
                @field(t, f.name).clearRetainingCapacity();
            }
        }
    }

    pub fn pathCount(t: *const Toolpaths) usize {
        return t.path_ends.items.len;
    }

    pub fn layerCount(t: *const Toolpaths) usize {
        return t.layer_ends.items.len;
    }

    /// The index in `points` (in points, not floats) of the first point of
    /// a path.
    pub fn pathStart(t: *const Toolpaths, path: usize) usize {
        return if (path == 0) 0 else t.path_ends.items[path - 1];
    }

    /// The first path of a layer.
    fn layerStart(t: *const Toolpaths, layer: usize) usize {
        return if (layer == 0) 0 else t.layer_ends.items[layer - 1];
    }

    /// The nozzle z range of a path: the layer z for a planar path.
    pub fn pathZRange(t: *const Toolpaths, path: usize, layer: usize) [2]f32 {
        const zl = t.layer_z.items[layer];
        const k = t.path_z_start.items[path];
        if (k == no_z) return .{ zl, zl };
        const n = t.path_ends.items[path] - t.pathStart(path);
        var lo: f32 = std.math.inf(f32);
        var hi: f32 = -std.math.inf(f32);
        for (t.point_z.items[k..][0..n]) |z| {
            lo = @min(lo, z);
            hi = @max(hi, z);
        }
        return .{ lo, hi };
    }

    /// The length of a path in mm, with the closing segment of a closed
    /// path.
    pub fn pathLength(t: *const Toolpaths, path: usize) f64 {
        const start = t.pathStart(path);
        const end: usize = t.path_ends.items[path];
        const pts = t.points.items;
        var len: f64 = 0;
        var k = start;
        while (k + 1 < end) : (k += 1) len += std.math.hypot(@as(f64, pts[2 * k + 2] - pts[2 * k]), @as(f64, pts[2 * k + 3] - pts[2 * k + 1]));
        if (t.path_closed.items[path] != 0 and end - start > 2) {
            len += std.math.hypot(@as(f64, pts[2 * start] - pts[2 * (end - 1)]), @as(f64, pts[2 * start + 1] - pts[2 * (end - 1) + 1]));
        }
        return len;
    }

    /// The layer of a path, or null if there is no such path.
    pub fn layerOfPath(t: *const Toolpaths, path: usize) ?usize {
        if (path >= t.pathCount()) return null;
        // The first layer whose end is after the path.
        var lo: usize = 0;
        var hi: usize = t.layerCount();
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (t.layer_ends.items[mid] <= path) lo = mid + 1 else hi = mid;
        }
        return if (lo < t.layerCount()) lo else null;
    }

    /// The path of `layer` nearest to (x, y) mm, within twice the line
    /// width, or null. For a click in a 2D layer view.
    pub fn pickInLayer(t: *const Toolpaths, layer: usize, x: f64, y: f64) ?usize {
        if (layer >= t.layerCount()) return null;
        return t.nearestPath(layer, x, y, null, 2 * @as(f64, t.layer_width.items[layer]));
    }

    /// The path of `feature` nearest to (x, y) on `layer` (or on the last
    /// layer, if the part has fewer layers now), at any distance. A shell
    /// uses it to keep a selection after a new slice moves the line (for
    /// example, a new skirt distance moves the skirt).
    pub fn pickFeature(t: *const Toolpaths, layer: usize, feature: u8, x: f64, y: f64) ?usize {
        if (t.layerCount() == 0) return null;
        return t.nearestPath(@min(layer, t.layerCount() - 1), x, y, feature, std.math.inf(f64));
    }

    /// The path of `layer` (of `feature`, if not null) nearest to (x, y),
    /// closer than `limit`, or null.
    fn nearestPath(t: *const Toolpaths, layer: usize, x: f64, y: f64, feature: ?u8, limit: f64) ?usize {
        var best: ?usize = null;
        var best_d = limit;
        const pts = t.points.items;
        for (t.layerStart(layer)..t.layer_ends.items[layer]) |pi| {
            if (feature) |f| if (t.path_features.items[pi] != f) continue;
            const start = t.pathStart(pi);
            const end: usize = t.path_ends.items[pi];
            if (end - start < 2) continue;
            const closed = t.path_closed.items[pi] != 0;
            const segs = end - start - 1 + @as(usize, @intFromBool(closed and end - start > 2));
            for (0..segs) |k| {
                const a = start + k;
                const b = if (a + 1 < end) a + 1 else start;
                const d = segmentDistance(x, y, pts[2 * a], pts[2 * a + 1], pts[2 * b], pts[2 * b + 1]);
                if (d < best_d) {
                    best_d = d;
                    best = pi;
                }
            }
        }
        return best;
    }

    /// The bead height of a path (mm).
    pub fn pathHeight(t: *const Toolpaths, path: usize, layer: usize) f32 {
        if (path < t.path_height.items.len) return t.path_height.items[path];
        return t.layer_height.items[layer];
    }

    /// The time, length, and plastic of each feature.
    pub fn featureStats(t: *const Toolpaths) [feature_names.len]FeatureStats {
        var out: [feature_names.len]FeatureStats = @splat(.{});
        for (t.path_features.items, 0..) |f, p| {
            const len = t.pathLength(p);
            const s = &out[f];
            s.time += t.path_end_time.items[p] - t.path_start_time.items[p];
            s.length += len;
            s.volume += len * t.path_area.items[p];
            s.paths += 1;
        }
        return out;
    }

    /// A Job.LayerSink function. `ctx` is a *Toolpaths whose `gpa` is set.
    pub fn addLayer(ctx: ?*anyopaque, plan: *const zs.layer.LayerPlan, infos: []const zs.gcode.PathInfo) anyerror!void {
        const t: *Toolpaths = @ptrCast(@alignCast(ctx.?));
        const gpa = t.gpa.?;
        const pts = plan.points.points.items;
        const xy = try t.points.addManyAsSlice(gpa, 2 * pts.len);
        for (pts, 0..) |p, i| {
            xy[2 * i] = @floatCast(zs.geom.toMm(p.x));
            xy[2 * i + 1] = @floatCast(zs.geom.toMm(p.y));
        }
        const base: u32 = if (t.path_ends.items.len == 0) 0 else t.path_ends.items[t.path_ends.items.len - 1];
        const ends = try t.path_ends.addManyAsSlice(gpa, plan.points.ends.items.len);
        for (ends, plan.points.ends.items) |*d, e| d.* = base + e;
        const n = plan.paths.items.len;
        const features = try t.path_features.addManyAsSlice(gpa, n);
        const closed = try t.path_closed.addManyAsSlice(gpa, n);
        const area = try t.path_area.addManyAsSlice(gpa, n);
        const height = try t.path_height.addManyAsSlice(gpa, n);
        const start_time = try t.path_start_time.addManyAsSlice(gpa, n);
        const end_time = try t.path_end_time.addManyAsSlice(gpa, n);
        const retract = try t.path_retract.addManyAsSlice(gpa, n);
        const fan = try t.path_fan.addManyAsSlice(gpa, n);
        const modifier = try t.path_modifier.addManyAsSlice(gpa, n);
        for (plan.paths.items, modifier) |p, *m| {
            const k: u16 = if (p.region > 0 and p.region <= plan.region_modifier.len) plan.region_modifier[p.region - 1] else zs.layer.LayerPlan.no_modifier;
            m.* = if (k == zs.layer.LayerPlan.no_modifier) 0 else k + 1;
        }
        const part = try t.path_part.addManyAsSlice(gpa, n);
        for (plan.paths.items, part) |p, *q| q.* = plan.partOf(p);
        const z_start = try t.path_z_start.addManyAsSlice(gpa, n);
        for (plan.paths.items, 0..) |p, i| {
            z_start[i] = no_z;
            // The flow ratio of the part of the path.
            const pr = plan.pathResolved(p) orelse plan.resolved;
            const flow_ratio: f32 = @floatCast(if (pr) |r| r.settings.filament.flow_ratio else 1);
            if (p.z_start == zs.layer.Path.planar and p.w_start != zs.layer.Path.planar) {
                // A path whose width changes along it (Arachne walls): the
                // z of the layer, and the bead area of each point.
                z_start[i] = @intCast(t.point_z.items.len);
                const len = plan.points.get(i).len;
                const h = if (p.height > 0) p.height else plan.height;
                for (plan.point_w.items[p.w_start..][0..len]) |w| {
                    try t.point_z.append(gpa, @floatCast(plan.z));
                    try t.point_area.append(gpa, @as(f32, @floatCast(zs.flow.beadArea(w, h))) * flow_ratio);
                }
                continue;
            }
            if (p.z_start == zs.layer.Path.planar) continue;
            z_start[i] = @intCast(t.point_z.items.len);
            const len = plan.points.get(i).len;
            for (plan.point_z.items[p.z_start..][0..len]) |d| {
                try t.point_z.append(gpa, d.z);
                try t.point_area.append(gpa, d.area * flow_ratio);
            }
        }
        for (plan.paths.items, infos, 0..) |p, info, i| {
            features[i] = @intFromEnum(p.feature);
            closed[i] = @intFromBool(p.closed);
            area[i] = @floatCast(info.area);
            height[i] = if (p.height > 0) p.height else @floatCast(plan.height);
            start_time[i] = @floatCast(info.start_time);
            end_time[i] = @floatCast(info.end_time);
            retract[i] = @intFromBool(info.retracted);
            fan[i] = info.fan;
        }
        var slowed = false;
        for (infos) |info| slowed = slowed or info.slowed;
        try t.layer_slowed.append(gpa, @intFromBool(slowed));
        try t.layer_ends.append(gpa, @intCast(t.path_ends.items.len));
        try t.layer_z.append(gpa, @floatCast(plan.z));
        try t.layer_height.append(gpa, @floatCast(plan.height));
        try t.layer_width.append(gpa, @floatCast(plan.width));
    }
};

/// The paths of one layer in flat arrays of floats, in mm, ready to draw.
pub const LayerPaths = struct {
    gpa: Allocator,
    /// x, y pairs.
    points: []f32,
    /// The end of each path in `points`, in points (not floats).
    ends: []u32,
    features: []u8,
    closed: []u8,
    outline_points: []f32,
    outline_ends: []u32,
    z: f32,
    height: f32,
    width: f32,

    pub fn fromPlan(gpa: Allocator, plan: *const zs.layer.LayerPlan) Allocator.Error!LayerPaths {
        var lp: LayerPaths = .{
            .gpa = gpa,
            .points = &.{},
            .ends = &.{},
            .features = &.{},
            .closed = &.{},
            .outline_points = &.{},
            .outline_ends = &.{},
            .z = @floatCast(plan.z),
            .height = @floatCast(plan.height),
            .width = @floatCast(plan.width),
        };
        errdefer lp.deinit();
        lp.points = try toFloats(gpa, plan.points.points.items);
        lp.ends = try gpa.dupe(u32, plan.points.ends.items);
        lp.features = try gpa.alloc(u8, plan.paths.items.len);
        lp.closed = try gpa.alloc(u8, plan.paths.items.len);
        for (plan.paths.items, 0..) |p, i| {
            lp.features[i] = @intFromEnum(p.feature);
            lp.closed[i] = @intFromBool(p.closed);
        }
        lp.outline_points = try toFloats(gpa, plan.outline.points.items);
        lp.outline_ends = try gpa.dupe(u32, plan.outline.ends.items);
        return lp;
    }

    pub fn deinit(lp: *LayerPaths) void {
        lp.gpa.free(lp.points);
        lp.gpa.free(lp.ends);
        lp.gpa.free(lp.features);
        lp.gpa.free(lp.closed);
        lp.gpa.free(lp.outline_points);
        lp.gpa.free(lp.outline_ends);
    }
};

fn toFloats(gpa: Allocator, pts: []const zs.geom.Point) Allocator.Error![]f32 {
    const out = try gpa.alloc(f32, pts.len * 2);
    for (pts, 0..) |p, i| {
        out[2 * i] = @floatCast(zs.geom.toMm(p.x));
        out[2 * i + 1] = @floatCast(zs.geom.toMm(p.y));
    }
    return out;
}

/// The print time, the length, and the plastic of the lines of one
/// feature.
pub const FeatureStats = struct {
    time: f64 = 0,
    length: f64 = 0,
    volume: f64 = 0,
    paths: usize = 0,
};

/// The distance from (x, y) to the segment from (ax, ay) to (bx, by).
fn segmentDistance(x: f64, y: f64, ax: f32, ay: f32, bx: f32, by: f32) f64 {
    const dx: f64 = bx - ax;
    const dy: f64 = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 == 0) 0 else std.math.clamp(((x - ax) * dx + (y - ay) * dy) / len2, 0, 1);
    return std.math.hypot(x - (ax + t * dx), y - (ay + t * dy));
}
