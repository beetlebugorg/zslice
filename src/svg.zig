//! An SVG picture of one layer plan, to see what the slicer made.
//!
//! The outline is a gray area. Each path is a line of the line width, with
//! one color for each feature. Thin gray lines show the travel moves.

const std = @import("std");
const Writer = std.Io.Writer;
const geom = @import("geom.zig");
const layer_mod = @import("layer.zig");
const Feature = @import("settings.zig").Feature;

fn color(f: Feature) []const u8 {
    return switch (f) {
        .outer_wall => "#d9480f",
        .inner_wall => "#f59f00",
        .skin => "#1c7ed6",
        .infill => "#2b8a3e",
    };
}

pub fn writeLayer(w: *Writer, lp: *const layer_mod.LayerPlan) Writer.Error!void {
    var box = lp.outline.bounds();
    if (box.isEmpty()) box = .{ .min = .init(0, 0), .max = .init(1000, 1000) };
    const margin: i64 = 2000;
    const x0 = box.min.x - margin;
    const y0 = box.min.y - margin;
    const wd = box.max.x - box.min.x + 2 * margin;
    const ht = box.max.y - box.min.y + 2 * margin;
    const stroke = geom.fromMm(lp.width);

    // SVG y goes down. The flip makes y go up, as on the printer.
    try w.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="{d} {d} {d} {d}" width="{d}mm" height="{d}mm">
        \\<rect x="{d}" y="{d}" width="{d}" height="{d}" fill="#ffffff"/>
        \\<g transform="translate(0 {d}) scale(1 -1)" fill="none" stroke-linecap="round" stroke-linejoin="round">
        \\
    , .{ x0, y0, wd, ht, @divTrunc(wd, 1000) * 4, @divTrunc(ht, 1000) * 4, x0, y0, wd, ht, 2 * y0 + ht });

    // The outline.
    try w.writeAll("<path fill=\"#e9ecef\" stroke=\"#868e96\" stroke-width=\"40\" fill-rule=\"nonzero\" d=\"");
    for (0..lp.outline.count()) |i| try writePath(w, lp.outline.get(i), true);
    try w.writeAll("\"/>\n");

    // Travel moves between paths.
    try w.writeAll("<path stroke=\"#adb5bd\" stroke-width=\"30\" stroke-dasharray=\"200 200\" d=\"");
    var last: ?geom.Point = null;
    for (lp.paths.items, 0..) |path, i| {
        const pts = lp.points.get(i);
        if (pts.len == 0) continue;
        if (last) |l| try w.print("M{d} {d}L{d} {d}", .{ l.x, l.y, pts[0].x, pts[0].y });
        last = if (path.closed) pts[0] else pts[pts.len - 1];
    }
    try w.writeAll("\"/>\n");

    // The paths, one SVG path for each feature.
    for (std.enums.values(Feature)) |f| {
        try w.print("<path stroke=\"{s}\" stroke-opacity=\"0.85\" stroke-width=\"{d}\" d=\"", .{ color(f), stroke });
        for (lp.paths.items, 0..) |path, i| {
            if (path.feature != f) continue;
            try writePath(w, lp.points.get(i), path.closed);
        }
        try w.writeAll("\"/>\n");
    }
    try w.writeAll("</g>\n</svg>\n");
}

fn writePath(w: *Writer, pts: []const geom.Point, closed: bool) Writer.Error!void {
    for (pts, 0..) |p, i| try w.print("{s}{d} {d}", .{ if (i == 0) "M" else "L", p.x, p.y });
    if (closed) try w.writeAll("Z");
}
