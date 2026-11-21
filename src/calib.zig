//! Calibration prints: the test parts and the steps of a calibration.
//!
//! A calibration is an ordinary plate. The test part is a mesh that this
//! file makes, and the settings of the plate vary the value under test:
//!
//! - temperature: a tower of blocks, one block for each nozzle
//!   temperature, the hottest at the bottom, in steps of 5 °C over the
//!   usual range of the material. A thin pillar next to the tower shows
//!   the strings. Each block is a range of layers with its own
//!   `filament.nozzle_temp` (a layer override).
//! - retraction: two pillars on a base. Each band of 5 mm is a range of
//!   layers with its own retraction length (`filament.retract_ratio`
//!   times `machine.retract_length`). The strings between the pillars
//!   show the length that is long enough.
//! - flow: a row of flat cubes, each a part with its own
//!   `filament.flow_ratio`, from 80 % to 120 % of the flow now.
//! - pressure advance: a square tower with one wall and no top, so each
//!   layer is a thin wall with four sharp corners, at the full wall
//!   speed. Each band of 4 mm is a range of layers with its own
//!   `filament.pressure_advance`. This is the tuning tower of Klipper
//!   (a hollow square, a higher value each band), with bands in place of
//!   a value for each layer.
//!
//! The user sees each value in the settings of the plate (the layer
//! ranges, the settings of each part), and can change it. Each step has
//! a label: the text of the value on the face of its block (label.zig),
//! when the printer can print it in another filament.
//!
//! References (see docs/references/klipper-marlin-firmware.md and
//! docs/references/orcaslicer.md): the pressure advance tuning tower of
//! Klipper, and the calibration prints of OrcaSlicer (the temperature
//! tower, the flow test, the retraction test).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const settings_mod = @import("settings.zig");
const Mesh = mesh_mod.Mesh;
const Settings = settings_mod.Settings;

pub const Kind = enum(u8) {
    temperature,
    retraction,
    flow,
    pressure_advance,

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .temperature => "Temperature tower",
            .retraction => "Retraction test",
            .flow => "Flow test",
            .pressure_advance => "Pressure advance tower",
        };
    }
};

/// One value of the test: the value of `Plan.setting` that it prints
/// with, and its text ("215", "0.4", "-5 %").
pub const Step = struct {
    value: f64,
    text: []const u8,
    /// The layers of the step (mm), for a step of a range of layers.
    z_min: f64 = 0,
    z_max: f64 = 0,
    /// The part of the step, for a step that is a part.
    part: usize = 0,
};

/// A label of a step: a text on a face of a part, in the frame of the
/// part (the center of its footprint at x = y = 0, the bed at z = 0).
pub const Label = struct {
    part: usize,
    text: []const u8,
    origin: [3]f64,
    normal: [3]f64,
    right: [3]f64,
    size: f64,
};

/// A test part, and the settings that it has of its own.
pub const Part = struct {
    name: []const u8,
    mesh: Mesh,
    changes: []const settings_mod.Change = &.{},
};

pub const Plan = struct {
    kind: Kind,
    /// The name of the plate.
    name: []const u8,
    /// The setting that the steps vary, and that "use this value" sets.
    setting: []const u8,
    /// Each step is a range of layers (true) or a part (false).
    layers: bool,
    steps: []const Step,
    parts: []Part,
    labels: []const Label,
    /// How to read the print, and which setting to change.
    note: []const u8,

    /// Frees the meshes that are still in the plan (the caller can take
    /// them, and set them to `.empty`).
    pub fn deinit(p: *Plan, gpa: Allocator) void {
        for (p.parts) |*part| part.mesh.deinit(gpa);
    }
};

pub const Error = Allocator.Error || mesh_mod.Error || error{NoRetraction};

/// The usual nozzle temperatures of a material (°C, from low to high).
pub fn tempRange(material: []const u8, now: f64) [2]f64 {
    const table = [_]struct { []const u8, f64, f64 }{
        .{ "PLA", 190, 230 },  .{ "PETG", 225, 255 }, .{ "PET", 225, 255 },
        .{ "ABS", 230, 260 },  .{ "ASA", 240, 270 },  .{ "TPU", 210, 240 },
        .{ "PA", 250, 290 },   .{ "PC", 260, 300 },   .{ "PVA", 185, 215 },
        .{ "HIPS", 220, 250 }, .{ "PP", 210, 240 },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(t[0], material)) return .{ t[1], t[2] };
    // Another material: 15 °C on each side of the temperature now.
    const c = @round(now / 5) * 5;
    return .{ c - 15, c + 15 };
}

/// The plan of a calibration with the settings `s`. The texts are in
/// `arena`, the meshes in `gpa`.
pub fn plan(gpa: Allocator, arena: Allocator, kind: Kind, s: Settings) Error!Plan {
    return switch (kind) {
        .temperature => temperature(gpa, arena, s),
        .retraction => retraction(gpa, arena, s),
        .flow => flow(gpa, arena, s),
        .pressure_advance => pressureAdvance(gpa, arena, s),
    };
}

fn temperature(gpa: Allocator, arena: Allocator, s: Settings) Error!Plan {
    const r = tempRange(s.filament.material, s.filament.nozzle_temp);
    const n: usize = @intFromFloat(@round((r[1] - r[0]) / 5) + 1);
    const block_h: f64 = 10.0;
    const waist_h: f64 = 1.0;
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    // The tower: 20 x 10 mm blocks, with a waist under each block after
    // the first, so each block shows. A pillar 8 mm to the right.
    const w: f64 = 20.0;
    const d: f64 = 10.0;
    const pillar: f64 = 4.0;
    const gap: f64 = 8.0;
    const total_w = w + gap + pillar;
    const x0 = -total_w / 2;
    const y0 = -d / 2;
    const steps = try arena.alloc(Step, n);
    const labels = try arena.alloc(Label, n);
    for (0..n) |k| {
        const z: f64 = @as(f64, @floatFromInt(k)) * block_h;
        const t = r[1] - 5 * @as(f64, @floatFromInt(k));
        if (k > 0) {
            try mesh_mod.shapes.addBox(&b, x0 + 1.5, y0 + 1.5, z, x0 + w - 1.5, y0 + d - 1.5, z + waist_h);
            try mesh_mod.shapes.addBox(&b, x0, y0, z + waist_h, x0 + w, y0 + d, z + block_h);
        } else {
            try mesh_mod.shapes.addBox(&b, x0, y0, z, x0 + w, y0 + d, z + block_h);
        }
        const text = try std.fmt.allocPrint(arena, "{d}", .{t});
        steps[k] = .{ .value = t, .text = text, .z_min = if (k == 0) -settings_mod.part_z else z + 1e-3, .z_max = if (k + 1 == n) settings_mod.part_z else z + block_h };
        labels[k] = .{ .part = 0, .text = text, .origin = .{ x0 + w / 2, y0, z + waist_h + (block_h - waist_h) / 2 }, .normal = .{ 0, -1, 0 }, .right = .{ 1, 0, 0 }, .size = 5 };
    }
    const top: f64 = @as(f64, @floatFromInt(n)) * block_h;
    try mesh_mod.shapes.addBox(&b, x0 + w + gap, -pillar / 2, 0, x0 + total_w, pillar / 2, top);
    const parts = try arena.alloc(Part, 1);
    parts[0] = .{ .name = "Temperature tower", .mesh = try b.finish() };
    return .{
        .kind = .temperature,
        .name = try std.fmt.allocPrint(arena, "Temperature tower {d}-{d} °C", .{ r[1], r[0] }),
        .setting = "filament.nozzle_temp",
        .layers = true,
        .steps = steps,
        .parts = parts,
        .labels = labels,
        .note = try std.fmt.allocPrint(arena, "Each block prints at its own nozzle temperature: {d} °C at the bottom, then 5 °C less for each block, to {d} °C at the top. Look at each block: a smooth surface, sharp corners, few strings to the pillar, and layers that do not break apart when you bend the tower. Use the lowest temperature that does all of these well. It sets filament.nozzle_temp.", .{ r[1], r[0] }),
    };
}

fn retraction(gpa: Allocator, arena: Allocator, s: Settings) Error!Plan {
    const base = s.machine.retract_length;
    if (!(base > 0)) return error.NoRetraction;
    // The lengths (mm): a bowden extruder needs more.
    const step: f64 = if (s.machine.extruder == .bowden) 0.5 else 0.2;
    const n: usize = 8;
    const band: f64 = 5.0;
    const base_h: f64 = 1.0;
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    const p: f64 = 8.0;
    const gap: f64 = 30.0;
    const total = 2 * p + gap;
    const x0 = -total / 2;
    const top = base_h + @as(f64, @floatFromInt(n)) * band;
    // A thin base joins the pillars: it holds them on the bed.
    try mesh_mod.shapes.addBox(&b, x0, -p / 2, 0, x0 + total, p / 2, base_h);
    try mesh_mod.shapes.addBox(&b, x0, -p / 2, base_h, x0 + p, p / 2, top);
    try mesh_mod.shapes.addBox(&b, x0 + p + gap, -p / 2, base_h, x0 + total, p / 2, top);
    const steps = try arena.alloc(Step, n);
    const labels = try arena.alloc(Label, n);
    for (0..n) |k| {
        const z = base_h + @as(f64, @floatFromInt(k)) * band;
        const len = step * @as(f64, @floatFromInt(k));
        const text = try std.fmt.allocPrint(arena, "{d}", .{len});
        // The ratio of the retraction of the printer.
        const ratio = @round(len / base * 1e4) / 1e4;
        steps[k] = .{ .value = ratio, .text = text, .z_min = if (k == 0) -settings_mod.part_z else z + 1e-3, .z_max = if (k + 1 == n) settings_mod.part_z else z + band };
        labels[k] = .{ .part = 0, .text = text, .origin = .{ x0 + p / 2, -p / 2, z + band / 2 }, .normal = .{ 0, -1, 0 }, .right = .{ 1, 0, 0 }, .size = 3 };
    }
    const parts = try arena.alloc(Part, 1);
    parts[0] = .{ .name = "Retraction test", .mesh = try b.finish() };
    // The retraction for each band can be more than 5 times the length of
    // the printer: the limit of filament.retract_ratio.
    for (steps) |*st| st.value = @min(st.value, 5);
    return .{
        .kind = .retraction,
        .name = try std.fmt.allocPrint(arena, "Retraction test 0-{d} mm", .{step * @as(f64, @floatFromInt(n - 1))}),
        .setting = "filament.retract_ratio",
        .layers = true,
        .steps = steps,
        .parts = parts,
        .labels = labels,
        .note = try std.fmt.allocPrint(arena, "Each band of 5 mm retracts its own length: 0 mm at the bottom, then {d} mm more for each band. Look at the strings between the two pillars. Use the shortest length with no strings: a longer retraction takes time and can clog the nozzle. It sets filament.retract_ratio (the length over machine.retract_length, {d} mm).", .{ step, base }),
    };
}

fn flow(gpa: Allocator, arena: Allocator, s: Settings) Error!Plan {
    const n: usize = 9;
    const parts = try arena.alloc(Part, n);
    var made: usize = 0;
    errdefer for (parts[0..made]) |*p| p.mesh.deinit(gpa);
    const steps = try arena.alloc(Step, n);
    const labels = try arena.alloc(Label, n);
    const size: f64 = 20.0;
    const h: f64 = 4.0;
    for (0..n) |k| {
        const pct: i32 = (@as(i32, @intCast(k)) - 4) * 5;
        const ratio = @round(s.filament.flow_ratio * (1 + @as(f64, @floatFromInt(pct)) / 100) * 1e4) / 1e4;
        const text = if (pct > 0) try std.fmt.allocPrint(arena, "+{d}", .{pct}) else try std.fmt.allocPrint(arena, "{d}", .{pct});
        var b: mesh_mod.Builder = .init(gpa);
        errdefer b.deinit();
        try mesh_mod.shapes.addBox(&b, -size / 2, -size / 2, 0, size / 2, size / 2, h);
        const changes = try arena.alloc(settings_mod.Change, 1);
        changes[0] = .{ .name = "filament.flow_ratio", .value = try std.fmt.allocPrint(arena, "{d}", .{ratio}) };
        parts[k] = .{ .name = try std.fmt.allocPrint(arena, "Flow {s} %", .{text}), .mesh = try b.finish(), .changes = changes };
        made += 1;
        steps[k] = .{ .value = ratio, .text = try std.fmt.allocPrint(arena, "{s} %", .{text}), .part = k };
        labels[k] = .{ .part = k, .text = text, .origin = .{ 0, -size / 2, h / 2 }, .normal = .{ 0, -1, 0 }, .right = .{ 1, 0, 0 }, .size = 2.5 };
    }
    return .{
        .kind = .flow,
        .name = "Flow test 80-120 %",
        .setting = "filament.flow_ratio",
        .layers = false,
        .steps = steps,
        .parts = parts,
        .labels = labels,
        .note = try std.fmt.allocPrint(arena, "Each cube prints with its own flow: from 20 % less to 20 % more than the flow now ({d}), in steps of 5 %. The name of each part has its step. Look at the top of each cube: use the flow of the smoothest top, with no gaps between the lines and no ridges. It sets filament.flow_ratio.", .{s.filament.flow_ratio}),
    };
}

fn pressureAdvance(gpa: Allocator, arena: Allocator, s: Settings) Error!Plan {
    // The values: Klipper suggests 0.005 for each mm of a direct drive
    // tower, and 0.020 for a bowden extruder.
    const step: f64 = if (s.machine.extruder == .bowden) 0.08 else 0.02;
    const n: usize = 10;
    const band: f64 = 4.0;
    const side: f64 = 40.0;
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    const top = @as(f64, @floatFromInt(n)) * band;
    try mesh_mod.shapes.addBox(&b, -side / 2, -side / 2, 0, side / 2, side / 2, top);
    const steps = try arena.alloc(Step, n);
    const labels = try arena.alloc(Label, n);
    for (0..n) |k| {
        const z = @as(f64, @floatFromInt(k)) * band;
        const v = @round(step * @as(f64, @floatFromInt(k)) * 1e4) / 1e4;
        const text = try std.fmt.allocPrint(arena, "{d}", .{v});
        steps[k] = .{ .value = v, .text = text, .z_min = if (k == 0) -settings_mod.part_z else z + 1e-3, .z_max = if (k + 1 == n) settings_mod.part_z else z + band };
        labels[k] = .{ .part = 0, .text = text, .origin = .{ 0, -side / 2, z + band / 2 }, .normal = .{ 0, -1, 0 }, .right = .{ 1, 0, 0 }, .size = 2.5 };
    }
    const parts = try arena.alloc(Part, 1);
    // One wall, no infill, no top: thin walls with sharp corners, at the
    // full wall speed, so the corners show the pressure in the nozzle.
    const changes = try arena.dupe(settings_mod.Change, &.{
        .{ .name = "project.wall_count", .value = "1" },
        .{ .name = "project.infill_density", .value = "0" },
        .{ .name = "project.top_thickness", .value = "0" },
        .{ .name = "project.outer_wall_speed", .value = "1" },
        .{ .name = "project.inner_wall_speed", .value = "1" },
    });
    parts[0] = .{ .name = "Pressure advance tower", .mesh = try b.finish(), .changes = changes };
    return .{
        .kind = .pressure_advance,
        .name = try std.fmt.allocPrint(arena, "Pressure advance 0-{d}", .{step * @as(f64, @floatFromInt(n - 1))}),
        .setting = "filament.pressure_advance",
        .layers = true,
        .steps = steps,
        .parts = parts,
        .labels = labels,
        .note = try std.fmt.allocPrint(arena, "Each band of 4 mm prints with its own pressure advance: 0 at the bottom, then {d} more for each band. Look at the corners of the tower. Too low: a bulge at each corner. Too high: a round corner, and a gap in the wall after it. Leave out the corner where the layer starts. Use the value of the band with the sharpest corners; if two look the same, the lower one. It sets filament.pressure_advance. Klipper also suggests a slow corner speed for this test (SQUARE_CORNER_VELOCITY=1, ACCEL=500).", .{step}),
    };
}

const testing = std.testing;

test "the plans of the calibrations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s: Settings = .{};
    inline for (.{ Kind.temperature, Kind.retraction, Kind.flow, Kind.pressure_advance }) |k| {
        var p = try plan(testing.allocator, a, k, s);
        defer p.deinit(testing.allocator);
        try testing.expect(p.steps.len >= 8);
        try testing.expectEqual(p.labels.len, p.steps.len);
        // Each value is in the limits of its setting.
        const lim = settings_mod.limitOf(p.setting).?;
        for (p.steps) |st| try testing.expect(st.value >= lim[0] and st.value <= lim[1]);
        // The layer ranges cover the part with no gap.
        if (p.layers) for (p.steps[1..], p.steps[0 .. p.steps.len - 1]) |st, prev| {
            try testing.expectApproxEqAbs(prev.z_max, st.z_min - 1e-3, 1e-9);
        };
        for (p.parts) |part| {
            const bb = part.mesh.bounds();
            try testing.expectApproxEqAbs(@as(f64, 0), bb.min[2], 1e-9);
            try testing.expectApproxEqAbs(@as(f64, 0), bb.min[0] + bb.max[0], 1e-9);
        }
    }
    // PLA: 230 °C at the bottom, 190 °C at the top.
    var t = try plan(testing.allocator, a, .temperature, s);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 230), t.steps[0].value);
    try testing.expectEqual(@as(f64, 190), t.steps[t.steps.len - 1].value);
    // No retraction on the printer: no retraction test.
    s.machine.retract_length = 0;
    try testing.expectError(error.NoRetraction, plan(testing.allocator, a, .retraction, s));
}
