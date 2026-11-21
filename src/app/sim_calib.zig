//! The calibration of the print simulation (print_sim.zig) against real
//! prints. Each test slices a test part with the default settings (PLA at
//! 210 °C, 0.2 mm layers, a 0.4 mm nozzle, the fan on), simulates the
//! print, and checks the drop of the plastic against a value that people
//! measured on real printers:
//!
//! - Overhangs. A 45 degree overhang prints clean: the "45 degree rule"
//!   (Jiang, Xu, and Stringer 2019; Yang et al. 2021). PLA keeps its shape
//!   up to about 25 degrees from horizontal, 65 from vertical (Mititelu
//!   2026). A steeper overhang droops more.
//! - Bridges. PLA bridges with almost no visible sag up to 33 mm, and the
//!   deck of a 35 mm bridge drops about 1 mm. Past 37 mm, loose strands
//!   hang under the deck (Yang et al. 2021).
//! - Plastic over air. A slab that sticks out far over air with nothing
//!   under it falls in strands, and the layers on it fall too.
//!
//! The parts in tools/calib print the same tests on a real printer. The
//! sources are in docs/references/physics-and-materials.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = zs.app.App;
const mesh_mod = zs.mesh;
const testing = std.testing;

fn v(x: f64, y: f64, z: f64) mesh_mod.Vec3 {
    return .{ .x = @floatCast(x), .y = @floatCast(y), .z = @floatCast(z) };
}

/// A prism along x from x0 to x1 of a polygon in (y, z), counter
/// clockwise, star shaped from its first point.
fn prismX(b: *mesh_mod.Builder, poly: []const [2]f64, x0: f64, x1: f64) !void {
    const n = poly.len;
    for (0..n) |i| {
        const a = poly[i];
        const c = poly[(i + 1) % n];
        try b.addQuad(v(x0, a[0], a[1]), v(x0, c[0], c[1]), v(x1, c[0], c[1]), v(x1, a[0], a[1]));
    }
    for (1..n - 1) |i| {
        const a = poly[0];
        const p = poly[i];
        const q = poly[i + 1];
        try b.addTriangle(v(x1, a[0], a[1]), v(x1, p[0], p[1]), v(x1, q[0], q[1]));
        try b.addTriangle(v(x0, a[0], a[1]), v(x0, q[0], q[1]), v(x0, p[0], p[1]));
    }
}

/// A box in the coordinates of the test part.
const Box = struct { x0: f64, x1: f64, y0: f64, y1: f64, z0: f64, z1: f64 };

/// The outcome of the plastic in a box of the part.
const Outcome = struct {
    /// The largest drop of a mass under its place (mm).
    drop: f32 = 0,
    /// The masses that failed.
    failed: usize = 0,
    /// The layers with a failed mass.
    failed_layers: usize = 0,
    first_failed_layer: u32 = zs.print_sim.none,
};

/// A test part, sliced and simulated.
const Part = struct {
    app: *App,
    /// The low corner of the part in its own coordinates, and its size.
    lo: [3]f64,
    size: [3]f64,

    fn init(gpa: Allocator, b: *mesh_mod.Builder) !Part {
        return initWith(gpa, b, &.{});
    }

    /// A part sliced with these settings changed (name, value).
    fn initWith(gpa: Allocator, b: *mesh_mod.Builder, settings: []const [2][]const u8) !Part {
        return initOn(gpa, b, null, settings);
    }

    /// A part sliced on a printer of the library (its id), with these
    /// settings changed.
    fn initOn(gpa: Allocator, b: *mesh_mod.Builder, printer: ?[]const u8, settings: []const [2][]const u8) !Part {
        var mesh = try b.finish();
        defer mesh.deinit(gpa);
        const bounds = mesh.bounds();
        var stl: std.Io.Writer.Allocating = .init(gpa);
        defer stl.deinit();
        try mesh.writeStl(&stl.writer);
        const app = try App.create(gpa, null, null);
        errdefer app.destroy();
        try app.loadStl("calib.stl", stl.written());
        if (printer) |id| {
            const lib = try zs.printers.Library.parse(gpa, zs.printers.builtin_data);
            defer lib.deinit();
            var text: std.Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            try lib.profileText(lib.find(id) orelse return error.NoPrinter, 0, &text.writer);
            var diag: zs.profile.Diagnostic = .{};
            try app.applyProfile(.machine, id, text.written(), &diag);
        }
        for (settings) |kv| try app.setSetting(kv[0], kv[1]);
        try app.startSlice();
        app.stopWorkerForTest();
        if (app.getState() != .done) return error.SliceFailed;
        _ = try app.simulatePrint();
        return .{
            .app = app,
            .lo = bounds.min,
            .size = .{ bounds.max[0] - bounds.min[0], bounds.max[1] - bounds.min[1], bounds.max[2] - bounds.min[2] },
        };
    }

    fn deinit(p: *Part) void {
        p.app.destroy();
    }

    /// The outcome of the plastic that the slicer meant to put in the box
    /// (not the infill, which is inside the part).
    fn outcome(p: *const Part, box: Box) Outcome {
        const app = p.app;
        const r = app.sim.?;
        const tp = &app.toolpaths;
        const bed = app.partBounds().?;
        const sx = (bed[2] - bed[0]) / p.size[0];
        const sy = (bed[3] - bed[1]) / p.size[1];
        const fail_drop = (zs.print_sim.Params{}).fail_drop;
        var o: Outcome = .{};
        var layer: usize = 0;
        var last_failed: usize = std.math.maxInt(usize);
        for (r.masses) |m| {
            while (tp.layer_ends.items[layer] <= m.path) layer += 1;
            const f: zs.settings.Feature = @enumFromInt(tp.path_features.items[m.path]);
            if (f == .infill) continue;
            const x = p.lo[0] + (m.want[0] - bed[0]) / sx;
            const y = p.lo[1] + (m.want[1] - bed[1]) / sy;
            const z: f64 = m.want[2];
            if (x < box.x0 or x > box.x1 or y < box.y0 or y > box.y1 or z < box.z0 or z > box.z1) continue;
            const drop = m.want[2] - m.pos[2];
            o.drop = @max(o.drop, drop);
            if (drop > fail_drop) {
                o.failed += 1;
                o.first_failed_layer = @min(o.first_failed_layer, @as(u32, @intCast(layer)));
                if (layer != last_failed) {
                    o.failed_layers += 1;
                    last_failed = layer;
                }
            }
        }
        return o;
    }
};

/// The angles of the overhang fins, from vertical.
const fin_angles = [_]f64{ 30, 45, 60, 80 };
const fin_width = 6;
const fin_gap = 6;
const fin_reach = 5;
const fin_tip = 1.6;
// The back wall is deep, so the part stands: the app lets a part that
// cannot stand fall over.
const fin_back = 6;

/// A comb of fins on a back wall: the underside of each fin leans out at
/// its angle from vertical. All tops are flat at the same height.
fn overhangs(gpa: Allocator) !Part {
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    const h = finHeight();
    for (fin_angles, 0..) |a, k| {
        const x: f64 = @as(f64, @floatFromInt(k)) * (fin_width + fin_gap);
        const zb = h - fin_tip - fin_reach / @tan(std.math.degreesToRadians(a));
        const poly = [_][2]f64{ .{ -fin_back, h }, .{ -fin_back, 0 }, .{ 0, 0 }, .{ 0, zb }, .{ fin_reach, h - fin_tip }, .{ fin_reach, h } };
        try prismX(&b, &poly, x, x + fin_width);
    }
    return Part.init(gpa, &b);
}

fn finHeight() f64 {
    return fin_tip + fin_reach / @tan(std.math.degreesToRadians(fin_angles[0])) + 2;
}

/// The overhang part of fin k (the plastic over the slope and its tip).
fn finBox(k: usize) Box {
    const x: f64 = @as(f64, @floatFromInt(k)) * (fin_width + fin_gap);
    return .{ .x0 = x, .x1 = x + fin_width, .y0 = 0.2, .y1 = fin_reach, .z0 = 0, .z1 = finHeight() };
}

test "sim calibration: an overhang of 45 degrees prints clean, and a steeper one droops more" {
    const gpa = testing.allocator;
    var p = try overhangs(gpa);
    defer p.deinit();
    var drops: [fin_angles.len]f32 = undefined;
    for (&drops, 0..) |*d, k| d.* = p.outcome(finBox(k)).drop;
    // 45 degrees: the 45 degree rule. Less than a layer height of droop.
    try testing.expect(drops[1] < 0.2);
    // 30 degrees droops no more than 45.
    try testing.expect(drops[0] <= drops[1] + 0.05);
    // 60 degrees (30 from horizontal): PLA keeps its shape to 65.
    try testing.expect(drops[2] < 0.5);
    // 80 degrees: each layer sticks out 1.1 mm past the one under it, more
    // than two beads. It droops much more than 60.
    try testing.expect(drops[3] > 0.5);
    try testing.expect(drops[3] > 2 * drops[2]);
}

/// Fins of the calibration print of the user, on a printer like the
/// LulzBot TAZ Workhorse SE (a 0.5 mm nozzle).
const taz_angles = [_]f64{ 60, 65, 70, 75, 80 };

/// The fins of tools/calib/gen.py: 8 mm out from a back wall of 4 mm, a
/// tip of 2 mm, 6 mm wide with gaps of 2 mm, all tops at the height of
/// the 30 degree fin.
const calib_reach = 8;
const calib_tip = 2;
const calib_back = 4;
const calib_pitch = 8;

fn calibHeight() f64 {
    return calib_tip + calib_reach / @tan(std.math.degreesToRadians(@as(f64, 30))) + 0.5;
}

/// The PLA 0.20 Standard profile of the user's TAZ (its Cura stack, as
/// `zslice import cura` reads it; see tools/calib/README.md).
const taz_pla_020 = [_][2][]const u8{
    .{ "project.layer_height", "0.2" },
    .{ "project.first_layer_height", "0.25" },
    .{ "project.wall_count", "3" },
    .{ "project.top_thickness", "1" },
    .{ "project.bottom_thickness", "1" },
    .{ "project.infill_density", "0.2" },
    .{ "project.infill_pattern", "gyroid" },
    .{ "project.outer_wall_speed", "0.417" },
    .{ "project.inner_wall_speed", "0.667" },
    .{ "project.skin_speed", "0.583" },
    .{ "project.infill_speed", "0.917" },
    .{ "project.first_layer_speed", "0.3" },
    .{ "project.slow_layers", "2" },
    .{ "filament.diameter", "2.85" },
    .{ "filament.nozzle_temp", "210" },
    .{ "filament.fan_speed", "1" },
    .{ "filament.min_layer_time", "10" },
};

fn tazOverhangs(gpa: Allocator) !Part {
    return calibFins(gpa, null, &.{.{ "machine.nozzle_diameter", "0.5" }});
}

fn calibFins(gpa: Allocator, printer: ?[]const u8, settings: []const [2][]const u8) !Part {
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    const h = calibHeight();
    for (taz_angles, 0..) |a, k| {
        const x: f64 = @as(f64, @floatFromInt(k)) * calib_pitch;
        const zb = h - calib_tip - calib_reach / @tan(std.math.degreesToRadians(a));
        const poly = [_][2]f64{ .{ -calib_back, h }, .{ -calib_back, 0 }, .{ 0, 0 }, .{ 0, zb }, .{ calib_reach, h - calib_tip }, .{ calib_reach, h } };
        try prismX(&b, &poly, x, x + fin_width);
        // The back wall between the fins.
        if (k + 1 < taz_angles.len) try mesh_mod.shapes.addBox(&b, x + fin_width, -calib_back, 0, x + calib_pitch, 0, h);
    }
    return Part.initOn(gpa, &b, printer, settings);
}

test "sim calibration: on the TAZ of the user with its PLA profile, 75 degree fins fall in strands" {
    const gpa = testing.allocator;
    var p = try calibFins(gpa, "lulzbot-taz-workhorse-se-0-5-mm", &taz_pla_020);
    defer p.deinit();
    var out: [taz_angles.len]Outcome = undefined;
    for (&out, 0..) |*o, k| {
        const x: f64 = @as(f64, @floatFromInt(k)) * calib_pitch;
        o.* = p.outcome(.{ .x0 = x, .x1 = x + fin_width, .y0 = 0.2, .y1 = calib_reach, .z0 = 0, .z1 = calibHeight() - calib_tip + 0.6 });
    }
    for (out[0..2]) |o| try testing.expectEqual(@as(usize, 0), o.failed);
    try testing.expectEqual(@as(usize, 0), out[2].failed);
    try testing.expect(out[3].failed > 0);
    try testing.expect(out[4].failed > 0);
}

test "sim calibration: the overhang fins of the user's print: smooth to 65 degrees, a little rough at 70, strands from 75" {
    const gpa = testing.allocator;
    var p = try tazOverhangs(gpa);
    defer p.deinit();
    var out: [taz_angles.len]Outcome = undefined;
    for (&out, 0..) |*o, k| {
        // The plastic of the fin under its top skin.
        const x: f64 = @as(f64, @floatFromInt(k)) * calib_pitch;
        o.* = p.outcome(.{ .x0 = x, .x1 = x + fin_width, .y0 = 0.2, .y1 = calib_reach, .z0 = 0, .z1 = calibHeight() - calib_tip + 0.6 });
    }
    // The user printed tools/calib/parts/overhang.stl on a TAZ Workhorse
    // SE with PLA: smooth from 30 to 65 degrees, a little rough at the root
    // at 70, loose strands at 75 and 80.
    for (out[0..2]) |o| {
        try testing.expectEqual(@as(usize, 0), o.failed);
        try testing.expect(o.drop < 0.2);
    }
    try testing.expectEqual(@as(usize, 0), out[2].failed);
    try testing.expect(out[2].drop < 1.5);
    // 75 degrees droops; with these settings (the profile of the printer
    // is not the one of the user) it stays under fail_drop. With the
    // profile of the user (tools/calib/sheet.csv) it falls in strands.
    try testing.expect(out[3].drop > 0.5);
    try testing.expect(out[4].failed > 0);
}

const spans = [_]f64{ 5, 20, 35, 60 };
const pier = 4;
const pier_h = 4;
const deck = 0.8;
const deck_w = 5;
const bridge_pitch = 10;

/// Bridges of each span on two piers, side by side.
fn bridges(gpa: Allocator) !Part {
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    for (spans, 0..) |s, k| {
        const y: f64 = @as(f64, @floatFromInt(k)) * bridge_pitch;
        try mesh_mod.shapes.addBox(&b, 0, y, 0, pier, y + deck_w, pier_h);
        try mesh_mod.shapes.addBox(&b, pier + s, y, 0, 2 * pier + s, y + deck_w, pier_h);
        try mesh_mod.shapes.addBox(&b, 0, y, pier_h, 2 * pier + s, y + deck_w, pier_h + deck);
    }
    return Part.init(gpa, &b);
}

/// The middle third of the deck of bridge k.
fn midDeck(k: usize) Box {
    const y: f64 = @as(f64, @floatFromInt(k)) * bridge_pitch;
    const s = spans[k];
    return .{ .x0 = pier + s / 3, .x1 = pier + 2 * s / 3, .y0 = y, .y1 = y + deck_w, .z0 = pier_h, .z1 = pier_h + deck };
}

test "sim calibration: a bridge sags little up to 33 mm, about 1 mm at 35 mm, and hangs in strands past 37 mm" {
    const gpa = testing.allocator;
    var p = try bridges(gpa);
    defer p.deinit();
    const short = p.outcome(midDeck(0));
    const mid = p.outcome(midDeck(1));
    const limit = p.outcome(midDeck(2));
    const long = p.outcome(midDeck(3));
    try testing.expect(short.drop < 0.2);
    // Yang et al. saw almost no sag below 33 mm. The model gives about
    // 0.7 mm at 20 mm: a strand has no bending stiffness in the model
    // (see the limits in print_sim.zig). The calibration prints measure
    // this span.
    try testing.expect(mid.drop < 1 and mid.drop < limit.drop);
    try testing.expect(limit.drop > 0.5 and limit.drop < 2);
    try testing.expectEqual(@as(usize, 0), limit.failed);
    try testing.expect(long.failed > 0);
}

const post = 6;
const post_h = 4;
const slab = 1.0;
const reach = 25;

/// A post with a slab on it that sticks out 25 mm over air on each side
/// (on both sides, so the part stands).
fn cantilever(gpa: Allocator) !Part {
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    try mesh_mod.shapes.addBox(&b, reach, 0, 0, reach + post, post, post_h);
    try mesh_mod.shapes.addBox(&b, 0, 0, post_h, 2 * reach + post, post, post_h + slab);
    return Part.init(gpa, &b);
}

test "sim calibration: a slab far over air falls in strands, and the layers on it fall too" {
    const gpa = testing.allocator;
    var p = try cantilever(gpa);
    defer p.deinit();
    // The end of the slab, more than 10 mm out.
    const end = p.outcome(.{ .x0 = 0, .x1 = reach - 10, .y0 = 0, .y1 = post, .z0 = post_h, .z1 = post_h + slab });
    // Much of it falls: more than a layer of plastic.
    try testing.expect(end.failed > 50);
    // The first layer of the slab fails, and the layers on it fail too.
    const tp = &p.app.toolpaths;
    var first: u32 = 0;
    while (tp.layer_z.items[first] - 0.5 * tp.layer_height.items[first] < post_h) first += 1;
    try testing.expectEqual(first, end.first_failed_layer);
    try testing.expect(end.failed_layers >= 4);
}
