//! Import of the profiles of other slicers into zslice settings.
//!
//! The importer reads one file and gives the zslice settings that it
//! sets, with a report of each value. It reads these files:
//!
//! - A PrusaSlicer or OrcaSlicer config file (`.ini`): one `key = value`
//!   a line. A config bundle of PrusaSlicer has a section for each preset
//!   (`[print:Name]`); the importer reads the presets that the
//!   `[presets]` section names, or the first preset of each kind. The
//!   config block at the end of a G-code file ("; key = value") reads the
//!   same way.
//! - An OrcaSlicer or Bambu Studio preset (`.json`): an object with a
//!   text, or a list of texts (one for each extruder), for each key.
//! - A 3MF project of PrusaSlicer (`Metadata/Slic3r_PE.config`) or of
//!   OrcaSlicer and Bambu Studio (`Metadata/project_settings.config`).
//! - A Cura profile export (`.curaprofile`): a zip of `.inst.cfg` files.
//!   Its values go through the Cura table of import_cura.zig.
//!
//! The conversions:
//!
//! 1. A list value (one for each extruder) gives its first value.
//! 2. A percentage resolves against its own base in the source first. In
//!    PrusaSlicer, `external_perimeter_speed` is a percentage of
//!    `perimeter_speed`, `solid_infill_speed` of `infill_speed`, and
//!    `top_solid_infill_speed` of `solid_infill_speed`. A line width in
//!    percent is of the layer height in PrusaSlicer and of the nozzle in
//!    OrcaSlicer.
//! 3. A speed in mm/s becomes a ratio: the speed over the base speed of
//!    the ratio in zslice, `machine.max_speed` (see settings.Resolved).
//!    The machine values of the file apply first, so a file with a speed
//!    limit of the printer gives its own base.
//! 4. A count of top or bottom layers becomes a thickness (the count
//!    times the layer height), at least the minimum thickness of the file.
//! 5. A distance between support lines becomes a density.
//! 6. A support threshold angle of PrusaSlicer and OrcaSlicer is from the
//!    horizontal plane; zslice measures it from the vertical.
//! 7. Each value goes into the limits of its setting (settings.limits).
//!    A speed ratio goes into 0.01 to 1. A value that changes in the
//!    limits is a "clamp" in the report.
//!
//! Each key with no zslice setting is in the report, with the reason.
//! An OrcaSlicer preset that inherits another preset has only its own
//! changes: the report says that the values of the parent are not in the
//! file.
//!
//! References (see docs/references/prusaslicer.md and
//! docs/references/orcaslicer.md): the config keys and their meaning
//! (PrusaSlicer src/libslic3r/PrintConfig.cpp, OrcaSlicer
//! src/libslic3r/PrintConfig.cpp), the config bundle and the 3MF config
//! files; for Cura (docs/references/cura.md), the `.curaprofile` format.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const settings_mod = @import("settings.zig");
const Settings = settings_mod.Settings;
const zipfile = @import("zipfile.zig");
const import_cura = @import("import_cura.zig");

pub const Error = error{ NotProfile, OutOfMemory };

/// The kind of the file.
pub const Format = enum {
    prusa_ini,
    orca_ini,
    orca_json,
    prusa_3mf,
    orca_3mf,
    curaprofile,

    pub fn text(f: Format) []const u8 {
        return switch (f) {
            .prusa_ini => "PrusaSlicer config",
            .orca_ini => "OrcaSlicer config",
            .orca_json => "OrcaSlicer preset",
            .prusa_3mf => "PrusaSlicer project",
            .orca_3mf => "OrcaSlicer project",
            .curaprofile => "Cura profile",
        };
    }
};

/// One line of the report.
pub const Row = struct {
    pub const Kind = enum { set, clamp, near, unused };
    kind: Kind,
    /// The key of the source, and its value as the file has it.
    key: []const u8,
    value: []const u8,
    /// The zslice setting and its value (set, clamp, near).
    name: []const u8 = "",
    out: []const u8 = "",
    /// For a clamp: the value before the limits. For near and unused: the
    /// reason.
    note: []const u8 = "",
};

pub const Result = struct {
    format: Format,
    /// The settings to set, in order.
    changes: []const settings_mod.Change,
    rows: []const Row,

    /// The report: a line "format\t<text>", then one line for each row:
    ///   "set\tkey\tvalue\tname\tout"
    ///   "clamp\tkey\tvalue\tname\tout\twanted"
    ///   "near\tkey\tvalue\tname\tout\twhy"
    ///   "unused\tkey\tvalue\twhy"
    /// A tab or a line break in a value becomes a space.
    pub fn writeReport(r: Result, w: *Writer) Writer.Error!void {
        try w.print("format\t{s}\n", .{r.format.text()});
        for (r.rows) |row| {
            try w.print("{s}\t{f}\t{f}", .{ @tagName(row.kind), flat(row.key), flat(row.value) });
            switch (row.kind) {
                .set => try w.print("\t{s}\t{f}\n", .{ row.name, flat(row.out) }),
                .clamp, .near => try w.print("\t{s}\t{f}\t{f}\n", .{ row.name, flat(row.out), flat(row.note) }),
                .unused => try w.print("\t{f}\n", .{flat(row.note)}),
            }
        }
    }
};

const Flat = struct {
    t: []const u8,
    pub fn format(f: Flat, w: *Writer) Writer.Error!void {
        // A long value (a G-code text) shows its start.
        const t = if (f.t.len > 80) f.t[0..80] else f.t;
        for (t) |ch| try w.writeByte(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch);
        if (f.t.len > 80) try w.writeAll("...");
    }
};
fn flat(t: []const u8) Flat {
    return .{ .t = t };
}

/// Reads a profile file. `name` is the file name (for its extension).
/// `base` has the settings now: the values that the file does not set
/// (the base speed, the layer height) come from it. The texts of the
/// result are in `arena`.
pub fn read(arena: Allocator, bytes: []const u8, name: []const u8, base: *const Settings) Error!Result {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) return readZip(arena, bytes, base);
    const t = std.mem.trimStart(u8, bytes, " \t\r\n\xef\xbb\xbf");
    if (t.len > 0 and t[0] == '{') {
        var kv: Values = .empty;
        try readJson(arena, t, &kv);
        return convert(arena, .orca_json, &kv, base);
    }
    if (std.mem.indexOf(u8, t, "[values]") != null and std.mem.indexOf(u8, t, "[general]") != null) {
        var cfgs = [_][]const u8{t};
        return readCura(arena, &cfgs, base);
    }
    _ = name;
    var kv: Values = .empty;
    try readIni(arena, t, &kv);
    if (kv.count() == 0) return error.NotProfile;
    return convert(arena, if (isOrca(&kv)) .orca_ini else .prusa_ini, &kv, base);
}

/// The keys and values of a file, in the order of the file. A later key
/// replaces an earlier one.
const Values = std.StringArrayHashMapUnmanaged([]const u8);

fn readZip(arena: Allocator, bytes: []const u8, base: *const Settings) Error!Result {
    const entries = zipfile.readAllLimited(arena, bytes, 64 << 20) catch return error.NotProfile;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "Metadata/project_settings.config")) {
            var kv: Values = .empty;
            try readJson(arena, e.data, &kv);
            return convert(arena, .orca_3mf, &kv, base);
        }
        if (std.mem.eql(u8, e.name, "Metadata/Slic3r_PE.config")) {
            var kv: Values = .empty;
            try readIni(arena, e.data, &kv);
            return convert(arena, .prusa_3mf, &kv, base);
        }
    }
    // A .curaprofile: the global profile first, then the extruder.
    var cfgs: std.ArrayList([]const u8) = .empty;
    for (entries) |e| if (std.mem.indexOf(u8, e.data, "[values]") != null and std.mem.indexOf(u8, e.data, "position") == null) try cfgs.append(arena, e.data);
    for (entries) |e| if (std.mem.indexOf(u8, e.data, "[values]") != null and std.mem.indexOf(u8, e.data, "position") != null) try cfgs.append(arena, e.data);
    if (cfgs.items.len == 0) return error.NotProfile;
    return readCura(arena, cfgs.items, base);
}

/// The lines of an INI text. "; key = value" (a G-code footer, a 3MF
/// config) reads as "key = value". A bundle keeps the sections that
/// `[presets]` names, or the first section of each kind.
fn readIni(arena: Allocator, text: []const u8, kv: *Values) Allocator.Error!void {
    // The presets that the bundle chose.
    var chosen: std.ArrayList([]const u8) = .empty;
    {
        var in_presets = false;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0 and line[0] == '[') {
                in_presets = std.mem.eql(u8, line, "[presets]");
                continue;
            }
            if (!in_presets) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const kind = std.mem.trim(u8, line[0..eq], " \t");
            const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
            // "print", "filament", "printer"; "filament_1" and on are the
            // other extruders.
            if (std.mem.eql(u8, kind, "print") or std.mem.eql(u8, kind, "filament") or std.mem.eql(u8, kind, "printer")) {
                try chosen.append(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ kind, v }));
            }
        }
    }
    var seen_kinds: [3]bool = .{ false, false, false };
    var keep = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const sec = std.mem.trim(u8, line, "[] ");
            const colon = std.mem.indexOfScalar(u8, sec, ':') orelse {
                keep = false;
                continue;
            };
            const kind = sec[0..colon];
            const k: ?usize = if (std.mem.eql(u8, kind, "print")) 0 else if (std.mem.eql(u8, kind, "filament")) 1 else if (std.mem.eql(u8, kind, "printer")) 2 else null;
            const ki = k orelse {
                keep = false;
                continue;
            };
            if (chosen.items.len > 0) {
                keep = false;
                for (chosen.items) |c| if (std.mem.eql(u8, c, sec)) {
                    keep = true;
                };
            } else {
                keep = !seen_kinds[ki];
            }
            if (keep) seen_kinds[ki] = true;
            continue;
        }
        if (!keep) continue;
        if (line[0] == '#') continue;
        if (line[0] == ';') line = std.mem.trimStart(u8, line[1..], " ");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0 or std.mem.indexOfAny(u8, key, " :") != null) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        try kv.put(arena, key, value);
    }
}

/// The keys of a JSON object. A list gives its texts with ";" between
/// them (as PrusaSlicer writes a list of texts); `first` takes the first.
fn readJson(arena: Allocator, text: []const u8, kv: *Values) Error!void {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.NotProfile;
    if (v != .object) return error.NotProfile;
    var it = v.object.iterator();
    while (it.next()) |e| {
        const t: ?[]const u8 = switch (e.value_ptr.*) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
            .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
            .bool => |b| if (b) "1" else "0",
            .array => |arr| blk: {
                var out: std.ArrayList(u8) = .empty;
                for (arr.items, 0..) |x, i| {
                    if (i > 0) try out.append(arena, ';');
                    switch (x) {
                        .string => |s| try out.appendSlice(arena, s),
                        .integer => |n| try out.print(arena, "{d}", .{n}),
                        .float => |f| try out.print(arena, "{d}", .{f}),
                        else => {},
                    }
                }
                break :blk out.items;
            },
            else => null,
        };
        if (t) |s| try kv.put(arena, e.key_ptr.*, s);
    }
}

/// An OrcaSlicer file has keys that PrusaSlicer does not have.
fn isOrca(kv: *const Values) bool {
    const keys = [_][]const u8{ "wall_loops", "sparse_infill_density", "initial_layer_print_height", "outer_wall_speed", "nozzle_temperature", "printable_area" };
    for (keys) |k| if (kv.contains(k)) return true;
    return false;
}

// ---- Cura ----

fn readCura(arena: Allocator, cfgs: []const []const u8, base: *const Settings) Error!Result {
    var pairs: std.ArrayList(import_cura.Pair) = .empty;
    for (cfgs) |cfg| {
        var section: []const u8 = "";
        var it = std.mem.splitScalar(u8, cfg, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[') {
                section = std.mem.trim(u8, line, "[] ");
                continue;
            }
            if (!std.mem.eql(u8, section, "values")) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            // A later layer (the extruder) replaces the value.
            for (pairs.items) |*p| {
                if (std.mem.eql(u8, p.key, key)) {
                    p.value = value;
                    break;
                }
            } else try pairs.append(arena, .{ .key = key, .value = value });
        }
    }
    const all = try import_cura.plateSettings(arena, pairs.items, base);
    var rows: std.ArrayList(Row) = .empty;
    for (pairs.items) |p| {
        // The zslice settings of this key alone, for the report.
        const one = try import_cura.plateSettings(arena, &.{p}, base);
        var any = false;
        for (one.sets) |s| {
            const final = for (all.sets) |f| {
                if (std.mem.eql(u8, f.name, s.name)) break f.value;
            } else s.value;
            any = true;
            // A speed over the base speed, or under 1 %, is a clamp.
            const n = std.fmt.parseFloat(f64, p.value) catch null;
            if (n != null and isSpeedRatio(s.name) and std.mem.startsWith(u8, p.key, "speed_")) {
                const want = n.? / base.machine.max_speed;
                if (want > 1 or want < 0.01) {
                    try rows.append(arena, .{ .kind = .clamp, .key = p.key, .value = p.value, .name = s.name, .out = final, .note = try num(arena, want) });
                    continue;
                }
            }
            try rows.append(arena, .{ .kind = .set, .key = p.key, .value = p.value, .name = s.name, .out = final });
        }
        for (one.ignored) |ig| {
            any = true;
            try rows.append(arena, .{ .kind = if (ig.near) .near else .unused, .key = ig.key, .value = ig.value, .note = ig.why });
        }
        if (!any) try rows.append(arena, .{ .kind = .unused, .key = p.key, .value = p.value, .note = "the zslice value is the same" });
    }
    return .{ .format = .curaprofile, .changes = all.sets, .rows = rows.items };
}

fn isSpeedRatio(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "project.")) return false;
    return std.mem.endsWith(u8, name, "_speed") and !std.mem.eql(u8, name, "project.coasting_speed");
}

// ---- PrusaSlicer and OrcaSlicer ----

/// How a value converts.
const Conv = enum {
    /// A number.
    number,
    /// A whole number.
    count,
    /// A percentage ("15%" or 15) that becomes a ratio.
    percent,
    /// A ratio as it is (1 or "100%").
    ratio,
    /// A speed in mm/s (or a percentage of `of`) that becomes a ratio.
    speed,
    /// A speed in mm/s that stays in mm/s (or a percentage of `of`).
    mm_s,
    /// 0 or 1, true or false.
    boolean,
    /// A text.
    text,
    /// A G-code text (PrusaSlicer writes "\n" for a line break).
    gcode,
    /// A distance that zslice has with the other sign.
    negate,
    /// A line width in mm, or in percent (see the file comment).
    width,
    /// An angle from the horizontal plane.
    angle_from_level,
    /// A distance in mm that becomes a count of layers.
    layers,
    /// A distance between lines that becomes a density.
    spacing,
    /// A text from a table (`choices`).
    choice,
};

const Map = struct {
    key: []const u8,
    name: []const u8,
    conv: Conv = .number,
    /// The key that a percentage is of.
    of: []const u8 = "",
    /// For `choice`: "from=to" pairs with "," between them; a "~" before
    /// "to" marks a near value.
    choices: []const u8 = "",
};

/// The keys of PrusaSlicer (first) and OrcaSlicer, in the order that the
/// importer converts them. A later row for the same zslice setting wins.
const table = [_]Map{
    // The printer.
    .{ .key = "printer_settings_id", .name = "machine.name", .conv = .text },
    .{ .key = "max_print_height", .name = "machine.max_height" },
    .{ .key = "printable_height", .name = "machine.max_height" },
    .{ .key = "nozzle_diameter", .name = "machine.nozzle_diameter" },
    .{ .key = "gcode_flavor", .name = "machine.gcode_flavor", .conv = .choice, .choices = "marlin=marlin,marlin2=marlin,marlinlegacy=marlin,klipper=klipper,reprap=reprap,reprapfirmware=reprap,repetier=repetier,sprinter=~marlin,teacup=~marlin,smoothie=~marlin" },
    .{ .key = "start_gcode", .name = "machine.start_gcode", .conv = .gcode },
    .{ .key = "machine_start_gcode", .name = "machine.start_gcode", .conv = .gcode },
    .{ .key = "end_gcode", .name = "machine.end_gcode", .conv = .gcode },
    .{ .key = "machine_end_gcode", .name = "machine.end_gcode", .conv = .gcode },
    .{ .key = "machine_max_feedrate_x", .name = "machine.max_speed_x" },
    .{ .key = "machine_max_feedrate_y", .name = "machine.max_speed_y" },
    .{ .key = "machine_max_speed_x", .name = "machine.max_speed_x" },
    .{ .key = "machine_max_speed_y", .name = "machine.max_speed_y" },
    .{ .key = "machine_max_acceleration_x", .name = "machine.max_accel_x" },
    .{ .key = "machine_max_acceleration_y", .name = "machine.max_accel_y" },
    .{ .key = "machine_max_acceleration_extruding", .name = "machine.max_accel" },
    .{ .key = "default_acceleration", .name = "machine.max_accel" },
    .{ .key = "machine_max_jerk_x", .name = "machine.corner_speed" },
    .{ .key = "default_jerk", .name = "machine.corner_speed" },
    .{ .key = "external_perimeter_acceleration", .name = "machine.outer_wall_accel" },
    .{ .key = "outer_wall_acceleration", .name = "machine.outer_wall_accel" },
    .{ .key = "perimeter_acceleration", .name = "machine.inner_wall_accel" },
    .{ .key = "inner_wall_acceleration", .name = "machine.inner_wall_accel" },
    .{ .key = "solid_infill_acceleration", .name = "machine.skin_accel" },
    .{ .key = "internal_solid_infill_acceleration", .name = "machine.skin_accel" },
    .{ .key = "top_surface_acceleration", .name = "machine.skin_accel" },
    .{ .key = "infill_acceleration", .name = "machine.infill_accel" },
    .{ .key = "sparse_infill_acceleration", .name = "machine.infill_accel" },
    .{ .key = "travel_acceleration", .name = "machine.travel_accel" },
    .{ .key = "first_layer_acceleration", .name = "machine.first_layer_accel" },
    .{ .key = "initial_layer_acceleration", .name = "machine.first_layer_accel" },
    .{ .key = "retract_length", .name = "machine.retract_length" },
    .{ .key = "retraction_length", .name = "machine.retract_length" },
    .{ .key = "retract_speed", .name = "machine.retract_speed" },
    .{ .key = "retraction_speed", .name = "machine.retract_speed" },
    .{ .key = "travel_speed", .name = "machine.travel_speed", .conv = .mm_s },
    .{ .key = "initial_layer_travel_speed", .name = "machine.first_layer_travel_speed", .conv = .mm_s, .of = "travel_speed" },
    .{ .key = "travel_speed_z", .name = "machine.max_z_speed" },
    .{ .key = "chamber_temperature", .name = "machine.chamber_temp" },
    .{ .key = "extruder_clearance_radius", .name = "machine.clearance_radius" },
    .{ .key = "extruder_clearance_height", .name = "machine.clearance_height" },
    .{ .key = "extruder_clearance_height_to_rod", .name = "machine.clearance_height" },
    .{ .key = "gcode_label_objects", .name = "machine.label_objects", .conv = .choice, .choices = "1=true,0=false,true=true,false=false,firmware=true,octoprint=true,disabled=false" },

    // The filament.
    .{ .key = "filament_settings_id", .name = "filament.name", .conv = .text },
    .{ .key = "filament_type", .name = "filament.material", .conv = .text },
    .{ .key = "filament_colour", .name = "filament.color", .conv = .text },
    .{ .key = "filament_diameter", .name = "filament.diameter" },
    .{ .key = "filament_density", .name = "filament.density" },
    .{ .key = "filament_cost", .name = "filament.price_per_kg" },
    .{ .key = "extrusion_multiplier", .name = "filament.flow_ratio" },
    .{ .key = "filament_flow_ratio", .name = "filament.flow_ratio" },
    .{ .key = "filament_max_volumetric_speed", .name = "filament.max_flow" },
    .{ .key = "temperature", .name = "filament.nozzle_temp" },
    .{ .key = "nozzle_temperature", .name = "filament.nozzle_temp" },
    .{ .key = "first_layer_temperature", .name = "filament.first_layer_nozzle_temp" },
    .{ .key = "nozzle_temperature_initial_layer", .name = "filament.first_layer_nozzle_temp" },
    .{ .key = "bed_temperature", .name = "filament.bed_temp" },
    .{ .key = "first_layer_bed_temperature", .name = "filament.first_layer_bed_temp" },
    .{ .key = "idle_temperature", .name = "filament.standby_temp" },
    .{ .key = "pressure_advance", .name = "filament.pressure_advance" },
    .{ .key = "min_fan_speed", .name = "filament.fan_speed", .conv = .percent },
    .{ .key = "fan_min_speed", .name = "filament.fan_speed", .conv = .percent },
    .{ .key = "max_fan_speed", .name = "filament.fan_max_speed", .conv = .percent },
    .{ .key = "fan_max_speed", .name = "filament.fan_max_speed", .conv = .percent },
    .{ .key = "disable_fan_first_layers", .name = "filament.fan_off_layers", .conv = .count },
    .{ .key = "close_fan_the_first_x_layers", .name = "filament.fan_off_layers", .conv = .count },
    .{ .key = "fan_below_layer_time", .name = "filament.fan_boost_time" },
    .{ .key = "fan_cooling_layer_time", .name = "filament.fan_boost_time" },
    .{ .key = "slowdown_below_layer_time", .name = "filament.min_layer_time" },
    .{ .key = "slow_down_layer_time", .name = "filament.min_layer_time" },
    .{ .key = "min_print_speed", .name = "filament.min_speed" },
    .{ .key = "slow_down_min_speed", .name = "filament.min_speed" },
    .{ .key = "xy_size_compensation", .name = "filament.xy_offset" },
    .{ .key = "xy_contour_compensation", .name = "filament.xy_offset" },
    .{ .key = "xy_hole_compensation", .name = "filament.hole_xy_offset" },
    .{ .key = "start_filament_gcode", .name = "filament.start_gcode", .conv = .gcode },
    .{ .key = "filament_start_gcode", .name = "filament.start_gcode", .conv = .gcode },
    .{ .key = "end_filament_gcode", .name = "filament.end_gcode", .conv = .gcode },
    .{ .key = "filament_end_gcode", .name = "filament.end_gcode", .conv = .gcode },

    // The print.
    .{ .key = "layer_height", .name = "project.layer_height" },
    .{ .key = "first_layer_height", .name = "project.first_layer_height", .conv = .width, .of = "layer_height" },
    .{ .key = "initial_layer_print_height", .name = "project.first_layer_height" },
    .{ .key = "extrusion_width", .name = "project.line_width", .conv = .width },
    .{ .key = "line_width", .name = "project.line_width", .conv = .width },
    .{ .key = "first_layer_extrusion_width", .name = "project.first_layer_line_width", .conv = .width, .of = "first_layer_height" },
    .{ .key = "initial_layer_line_width", .name = "project.first_layer_line_width", .conv = .width },
    .{ .key = "perimeters", .name = "project.wall_count", .conv = .count },
    .{ .key = "wall_loops", .name = "project.wall_count", .conv = .count },
    .{ .key = "external_perimeters_first", .name = "project.wall_order", .conv = .choice, .choices = "1=outer_first,0=inner_first" },
    .{ .key = "wall_sequence", .name = "project.wall_order", .conv = .choice, .choices = "inner wall/outer wall=inner_first,outer wall/inner wall=outer_first,inner-outer-inner wall=~inner_first" },
    .{ .key = "alternate_extra_wall", .name = "project.alternate_extra_wall", .conv = .boolean },
    .{ .key = "extra_perimeters_odd_layers", .name = "project.alternate_extra_wall", .conv = .boolean },
    .{ .key = "thin_walls", .name = "project.thin_walls", .conv = .boolean },
    .{ .key = "detect_thin_wall", .name = "project.thin_walls", .conv = .boolean },
    .{ .key = "perimeter_generator", .name = "project.wall_generator", .conv = .choice, .choices = "classic=classic,arachne=arachne" },
    .{ .key = "wall_generator", .name = "project.wall_generator", .conv = .choice, .choices = "classic=classic,arachne=arachne" },
    .{ .key = "gap_fill_enabled", .name = "project.gap_fill", .conv = .boolean },
    .{ .key = "seam_position", .name = "project.seam", .conv = .choice, .choices = "aligned=hidden,aligned_back=~rear,nearest=nearest,random=random,rear=rear,back=rear" },
    .{ .key = "spiral_vase", .name = "project.spiral_vase", .conv = .boolean },
    .{ .key = "spiral_mode", .name = "project.spiral_vase", .conv = .boolean },
    .{ .key = "fill_density", .name = "project.infill_density", .conv = .percent },
    .{ .key = "sparse_infill_density", .name = "project.infill_density", .conv = .percent },
    .{ .key = "fill_pattern", .name = "project.infill_pattern", .conv = .choice, .choices = infill_choices },
    .{ .key = "sparse_infill_pattern", .name = "project.infill_pattern", .conv = .choice, .choices = infill_choices },
    .{ .key = "fill_angle", .name = "project.infill_angle" },
    .{ .key = "infill_direction", .name = "project.infill_angle" },
    .{ .key = "solid_infill_direction", .name = "project.skin_angle" },
    .{ .key = "infill_every_layers", .name = "project.infill_layers", .conv = .count },
    .{ .key = "infill_overlap", .name = "project.infill_overlap", .conv = .percent },
    .{ .key = "infill_wall_overlap", .name = "project.infill_overlap", .conv = .percent },
    .{ .key = "top_fill_pattern", .name = "project.skin_pattern", .conv = .choice, .choices = skin_choices },
    .{ .key = "top_surface_pattern", .name = "project.skin_pattern", .conv = .choice, .choices = skin_choices },
    .{ .key = "ironing", .name = "project.ironing", .conv = .boolean },
    .{ .key = "ironing_type", .name = "project.ironing", .conv = .choice, .choices = "no ironing=false,top=true,topmost=~true,solid=~true" },
    .{ .key = "ironing_flowrate", .name = "project.ironing_flow", .conv = .percent },
    .{ .key = "ironing_flow", .name = "project.ironing_flow", .conv = .percent },
    .{ .key = "ironing_spacing", .name = "project.ironing_spacing" },
    .{ .key = "elefant_foot_compensation", .name = "project.first_layer_xy_offset", .conv = .negate },
    .{ .key = "avoid_crossing_perimeters", .name = "project.combing_mode", .conv = .choice, .choices = combing_choices },
    .{ .key = "reduce_crossing_wall", .name = "project.combing_mode", .conv = .choice, .choices = combing_choices },
    // The retraction of the travels is a printer setting (see
    // settings.Machine.z_hop).
    .{ .key = "retract_lift", .name = "machine.z_hop" },
    .{ .key = "z_hop", .name = "machine.z_hop" },
    // Auto Lift lifts the travels that leave the part; the other kinds
    // lift each retraction.
    .{ .key = "z_hop_types", .name = "machine.z_hop_only_crossing", .conv = .choice, .choices = "auto lift=true,normal lift=false,slope lift=false,spiral lift=false" },
    .{ .key = "retract_before_travel", .name = "machine.retract_min_travel" },
    .{ .key = "retraction_minimum_travel", .name = "machine.retract_min_travel" },
    .{ .key = "retract_layer_change", .name = "machine.retract_layer_change", .conv = .boolean },
    .{ .key = "retract_when_changing_layer", .name = "machine.retract_layer_change", .conv = .boolean },
    .{ .key = "wipe", .name = "machine.retract_wipe", .conv = .boolean },
    .{ .key = "wipe_distance", .name = "machine.retract_wipe_distance" },
    .{ .key = "bridge_fan_speed", .name = "project.bridge_fan", .conv = .percent },
    .{ .key = "overhang_fan_speed", .name = "project.bridge_fan", .conv = .percent },
    .{ .key = "bridge_flow_ratio", .name = "project.bridge_flow", .conv = .ratio },
    .{ .key = "bridge_flow", .name = "project.bridge_flow", .conv = .ratio },
    .{ .key = "slow_down_layers", .name = "project.slow_layers", .conv = .count },
    // The speeds: the bases of the percentages first.
    .{ .key = "perimeter_speed", .name = "project.inner_wall_speed", .conv = .speed },
    .{ .key = "inner_wall_speed", .name = "project.inner_wall_speed", .conv = .speed },
    .{ .key = "external_perimeter_speed", .name = "project.outer_wall_speed", .conv = .speed, .of = "perimeter_speed" },
    .{ .key = "outer_wall_speed", .name = "project.outer_wall_speed", .conv = .speed, .of = "inner_wall_speed" },
    .{ .key = "infill_speed", .name = "project.infill_speed", .conv = .speed },
    .{ .key = "sparse_infill_speed", .name = "project.infill_speed", .conv = .speed },
    .{ .key = "solid_infill_speed", .name = "project.skin_speed", .conv = .speed, .of = "infill_speed" },
    .{ .key = "internal_solid_infill_speed", .name = "project.skin_speed", .conv = .speed, .of = "sparse_infill_speed" },
    .{ .key = "support_material_speed", .name = "project.support_speed", .conv = .speed },
    .{ .key = "support_speed", .name = "project.support_speed", .conv = .speed },
    .{ .key = "support_material_interface_speed", .name = "project.support_interface_speed", .conv = .speed, .of = "support_material_speed" },
    .{ .key = "support_interface_speed", .name = "project.support_interface_speed", .conv = .speed, .of = "support_speed" },
    .{ .key = "bridge_speed", .name = "project.bridge_speed", .conv = .speed },
    .{ .key = "first_layer_speed", .name = "project.first_layer_speed", .conv = .speed, .of = "perimeter_speed" },
    .{ .key = "initial_layer_speed", .name = "project.first_layer_speed", .conv = .speed, .of = "inner_wall_speed" },
    .{ .key = "ironing_speed", .name = "project.ironing_speed", .conv = .speed, .of = "top_solid_infill_speed" },
    // The support.
    .{ .key = "support_material", .name = "project.support", .conv = .choice, .choices = "1=everywhere,0=off" },
    .{ .key = "enable_support", .name = "project.support", .conv = .choice, .choices = "1=everywhere,0=off" },
    .{ .key = "support_material_style", .name = "project.support_style", .conv = .choice, .choices = "grid=grid,snug=~grid,organic=tree" },
    .{ .key = "support_type", .name = "project.support_style", .conv = .choice, .choices = "normal(auto)=grid,normal(manual)=grid,tree(auto)=tree,tree(manual)=tree" },
    .{ .key = "support_material_threshold", .name = "project.support_angle", .conv = .angle_from_level },
    .{ .key = "support_threshold_angle", .name = "project.support_angle", .conv = .angle_from_level },
    .{ .key = "support_material_contact_distance", .name = "project.support_z_gap_layers", .conv = .layers },
    .{ .key = "support_top_z_distance", .name = "project.support_z_gap_layers", .conv = .layers },
    .{ .key = "support_material_xy_spacing", .name = "project.support_xy_gap", .conv = .width },
    .{ .key = "support_object_xy_distance", .name = "project.support_xy_gap" },
    .{ .key = "support_material_spacing", .name = "project.support_density", .conv = .spacing },
    .{ .key = "support_base_pattern_spacing", .name = "project.support_density", .conv = .spacing },
    .{ .key = "support_material_interface_layers", .name = "project.support_interface_layers", .conv = .count },
    .{ .key = "support_interface_top_layers", .name = "project.support_interface_layers", .conv = .count },
    .{ .key = "support_material_interface_spacing", .name = "project.support_interface_density", .conv = .spacing },
    .{ .key = "support_interface_spacing", .name = "project.support_interface_density", .conv = .spacing },
    // The order of the parts.
    .{ .key = "complete_objects", .name = "project.print_sequence", .conv = .choice, .choices = "1=by_object,0=by_layer" },
    .{ .key = "print_sequence", .name = "project.print_sequence", .conv = .choice, .choices = "by layer=by_layer,by object=by_object" },
    // The skirt and the brim.
    .{ .key = "skirts", .name = "project.skirt_loops", .conv = .count },
    .{ .key = "skirt_loops", .name = "project.skirt_loops", .conv = .count },
    .{ .key = "skirt_distance", .name = "project.skirt_distance" },
    .{ .key = "skirt_height", .name = "project.skirt_layers", .conv = .count },
    .{ .key = "brim_width", .name = "project.brim_width" },
    .{ .key = "brim_type", .name = "project.brim_location", .conv = .choice, .choices = "outer_only=outside,inner_only=inside,outer_and_inner=everywhere,auto_brim=~outside,brim_ears=~outside" },
};

/// Avoid crossing walls on or off: the combing of zslice in the whole
/// part, or none.
const combing_choices = "1=all,0=off,true=all,false=off";
const infill_choices = "rectilinear=lines,alignedrectilinear=lines,line=lines,grid=grid,triangles=triangles,stars=trihexagon,tri-hexagon=trihexagon,cubic=cubic,adaptivecubic=~cubic,supportcubic=~cubic,concentric=concentric,honeycomb=honeycomb,3dhoneycomb=~honeycomb,gyroid=gyroid,lightning=lightning,zig-zag=zigzag,zigzag=zigzag,crosshatch=~grid,hilbertcurve=~lines,archimedeanchords=~concentric,octagramspiral=~concentric";
const skin_choices = "monotonic=monotonic,monotonicline=monotonic,monotoniclines=monotonic,rectilinear=lines,alignedrectilinear=lines,concentric=concentric,hilbertcurve=~lines,archimedeanchords=~concentric,octagramspiral=~concentric";

const Ctx = struct {
    arena: Allocator,
    kv: *const Values,
    orca: bool,
    /// The settings with the changes so far.
    s: Settings,
    changes: std.ArrayList(settings_mod.Change) = .empty,
    rows: std.ArrayList(Row) = .empty,
    used: std.StringHashMapUnmanaged(void) = .empty,

    /// The value of a key: its first value for a list.
    fn get(c: *const Ctx, key: []const u8) ?[]const u8 {
        const v = c.kv.get(key) orelse return null;
        return first(v);
    }

    fn number(c: *const Ctx, key: []const u8) ?f64 {
        return parseNum(c.get(key) orelse return null);
    }

    /// Sets a zslice setting, in its limits, and adds a row.
    fn put(c: *Ctx, key: []const u8, value: []const u8, name: []const u8, out: []const u8, near: ?[]const u8) Allocator.Error!void {
        try c.used.put(c.arena, key, {});
        var text = out;
        var kind: Row.Kind = if (near != null) .near else .set;
        var note: []const u8 = near orelse "";
        if (settings_mod.limitOf(name)) |l| if (parseNum(out)) |n| {
            var lo = l[0];
            var hi = l[1];
            if (isSpeedRatio(name)) {
                lo = @max(lo, 0.01);
                hi = @min(hi, 1);
            }
            const cl = std.math.clamp(n, lo, hi);
            if (cl != n) {
                kind = .clamp;
                note = out;
                text = try num(c.arena, cl);
            }
        };
        var t = c.s;
        t.set(name, text) catch {
            try c.rows.append(c.arena, .{ .kind = .unused, .key = key, .value = value, .note = try std.fmt.allocPrint(c.arena, "not a value of {s}", .{name}) });
            return;
        };
        c.s = t;
        for (c.changes.items) |*ch| {
            if (std.mem.eql(u8, ch.name, name)) {
                ch.value = text;
                break;
            }
        } else try c.changes.append(c.arena, .{ .name = name, .value = text });
        try c.rows.append(c.arena, .{ .kind = kind, .key = key, .value = value, .name = name, .out = text, .note = note });
    }

    fn unused(c: *Ctx, key: []const u8, value: []const u8, why: []const u8) Allocator.Error!void {
        try c.used.put(c.arena, key, {});
        try c.rows.append(c.arena, .{ .kind = .unused, .key = key, .value = value, .note = why });
    }

    /// A value in mm/s: a number, or a percentage of key `of`.
    fn mmPerS(c: *const Ctx, text: []const u8, of: []const u8, depth: u32) ?f64 {
        const t = std.mem.trim(u8, text, " ");
        if (std.mem.endsWith(u8, t, "%")) {
            const p = parseNum(t[0 .. t.len - 1]) orelse return null;
            if (of.len == 0 or depth > 4) return null;
            const of_text = c.get(of) orelse return null;
            const of_map = mapOf(of);
            const base = c.mmPerS(of_text, if (of_map) |m| m.of else "", depth + 1) orelse return null;
            return p / 100 * base;
        }
        return parseNum(t);
    }
};

fn mapOf(key: []const u8) ?Map {
    for (table) |m| if (std.mem.eql(u8, m.key, key)) return m;
    return null;
}

/// The first value of a list ("215,215" or "a;b"). A G-code text and a
/// color keep their commas.
fn first(v: []const u8) []const u8 {
    const t = std.mem.trim(u8, v, " ");
    if (t.len > 0 and t[0] == '"') {
        // A list of quoted texts: the first text.
        var i: usize = 1;
        while (i < t.len) : (i += 1) {
            if (t[i] == '\\') {
                i += 1;
                continue;
            }
            if (t[i] == '"') return t[1..i];
        }
        return t[1..];
    }
    const sep = std.mem.indexOfAny(u8, t, ",;") orelse return t;
    // Only a list of numbers, of booleans, or of colors splits.
    const head = t[0..sep];
    if (parseNum(head) != null or head.len == 0 or head[0] == '#' or std.mem.eql(u8, head, "nil")) return head;
    return t;
}

fn parseNum(t: []const u8) ?f64 {
    const s = std.mem.trim(u8, t, " \"");
    const v = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

/// A number with at most 4 decimals, as a text.
fn num(arena: Allocator, v: f64) Allocator.Error![]const u8 {
    const r = @round(v * 1e4) / 1e4;
    return std.fmt.allocPrint(arena, "{d}", .{r});
}

fn isTrue(t: []const u8) ?bool {
    const s = std.mem.trim(u8, t, " \"");
    if (std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false")) return false;
    return null;
}

/// PrusaSlicer escapes a line break as "\n" and a backslash as "\\".
fn unescape(arena: Allocator, t: []const u8) Allocator.Error![]const u8 {
    var s = t;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(arena, switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => s[i],
            });
        } else try out.append(arena, s[i]);
    }
    return out.items;
}

/// Looks up `v` in "from=to" pairs. Returns the zslice text and if it is
/// a near value.
fn lookup(choices: []const u8, v: []const u8) ?struct { to: []const u8, near: bool } {
    var it = std.mem.splitScalar(u8, choices, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(pair[0..eq], v)) continue;
        const to = pair[eq + 1 ..];
        if (to.len > 0 and to[0] == '~') return .{ .to = to[1..], .near = true };
        return .{ .to = to, .near = false };
    }
    return null;
}

/// The size and the origin of a bed from its corners ("0x0,250x0,...").
fn bedOf(t: []const u8) ?[4]f64 {
    var lo: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
    var hi: [2]f64 = .{ -std.math.inf(f64), -std.math.inf(f64) };
    var it = std.mem.tokenizeAny(u8, t, ",;\" ");
    var n: usize = 0;
    while (it.next()) |p| {
        const x = std.mem.indexOfScalar(u8, p, 'x') orelse return null;
        const a = parseNum(p[0..x]) orelse return null;
        const b = parseNum(p[x + 1 ..]) orelse return null;
        lo = .{ @min(lo[0], a), @min(lo[1], b) };
        hi = .{ @max(hi[0], a), @max(hi[1], b) };
        n += 1;
    }
    if (n < 3) return null;
    return .{ hi[0] - lo[0], hi[1] - lo[1], lo[0], lo[1] };
}

/// The Bambu Studio and OrcaSlicer key of the bed temperature of a plate.
fn plateKey(b: settings_mod.BedType) []const u8 {
    return switch (b) {
        .cool_plate => "cool_plate_temp",
        .engineering_plate => "eng_plate_temp",
        .high_temp_plate => "hot_plate_temp",
        .textured_pei_plate => "textured_plate_temp",
        .supertack_plate => "supertack_plate_temp",
    };
}

fn convert(arena: Allocator, format: Format, kv: *const Values, base: *const Settings) Error!Result {
    var c: Ctx = .{ .arena = arena, .kv = kv, .orca = format == .orca_ini or format == .orca_json or format == .orca_3mf, .s = base.* };

    if (c.get("inherits")) |p| if (p.len > 0) {
        try c.unused("inherits", p, "the values of the parent profile are not in the file: zslice keeps its own values for them");
    };
    // The bed.
    for ([_][]const u8{ "bed_shape", "printable_area" }) |k| if (kv.get(k)) |v| {
        if (bedOf(v)) |b| {
            try c.put(k, v, "machine.bed_size_x", try num(arena, b[0]), null);
            try c.put(k, v, "machine.bed_size_y", try num(arena, b[1]), null);
            if (b[2] != 0 or b[3] != 0) {
                try c.put(k, v, "machine.origin_x", try num(arena, b[2]), null);
                try c.put(k, v, "machine.origin_y", try num(arena, b[3]), null);
            }
        } else try c.unused(k, v, "not a bed shape");
    };

    // The table: the machine rows first, so the base speed of the ratios
    // is the speed limit of the printer of the file.
    for ([_][]const u8{ "machine.", "filament.", "project." }) |group| {
        for (table) |m| {
            if (!std.mem.startsWith(u8, m.name, group)) continue;
            const raw = kv.get(m.key) orelse continue;
            try convertOne(&c, m, raw);
        }
        if (std.mem.eql(u8, group, "machine.")) {
            // The base speed: the slower axis limit of the file.
            const sx = c.number("machine_max_feedrate_x") orelse c.number("machine_max_speed_x");
            const sy = c.number("machine_max_feedrate_y") orelse c.number("machine_max_speed_y");
            if (sx != null and sy != null and sx.? > 0 and sy.? > 0) {
                const key = if (kv.contains("machine_max_feedrate_x")) "machine_max_feedrate_x" else "machine_max_speed_x";
                try c.put(key, kv.get(key).?, "machine.max_speed", try num(arena, @min(sx.?, sy.?)), "the slower of the X and Y limits");
            }
        }
    }

    // The top and the bottom: a count of layers, and a minimum thickness.
    const lh = c.s.project.layer_height;
    const shells = [_]struct { []const u8, []const u8, []const u8, []const u8, []const u8 }{
        .{ "top_solid_layers", "top_shell_layers", "top_solid_min_thickness", "top_shell_thickness", "project.top_thickness" },
        .{ "bottom_solid_layers", "bottom_shell_layers", "bottom_solid_min_thickness", "bottom_shell_thickness", "project.bottom_thickness" },
    };
    for (shells) |sh| {
        const ck = if (kv.contains(sh[0])) sh[0] else sh[1];
        const tk = if (kv.contains(sh[2])) sh[2] else sh[3];
        const count = c.number(ck);
        const min_t = c.number(tk);
        if (count == null and min_t == null) continue;
        const t = @max((count orelse 0) * lh, min_t orelse 0);
        const key = if (count != null) ck else tk;
        try c.put(key, c.get(key).?, sh[4], try num(arena, t), null);
        if (count != null and min_t != null) try c.used.put(arena, tk, {});
    }
    // Support on the bed only.
    for ([_][]const u8{ "support_material_buildplate_only", "support_on_build_plate_only" }) |k| if (c.get(k)) |v| {
        if (isTrue(v) orelse false) {
            if (c.s.project.support != .off) try c.put(k, v, "project.support", "buildplate", null) else try c.unused(k, v, "the support is off");
        } else try c.used.put(arena, k, {});
    };
    // The fan ramp: from the last layer with the fan off to the layer at
    // full speed.
    if (c.number("full_fan_speed_layer")) |full| {
        const off: f64 = @floatFromInt(c.s.filament.fan_off_layers);
        try c.put("full_fan_speed_layer", c.get("full_fan_speed_layer").?, "filament.fan_ramp_layers", try num(arena, @max(0, full - off - 1)), null);
    }
    // The retraction of the filament: a ratio of the retraction of the
    // printer.
    for ([_][]const u8{ "filament_retract_length", "filament_retraction_length" }) |k| if (c.get(k)) |v| {
        const n = parseNum(v) orelse {
            try c.used.put(arena, k, {}); // "nil": the value of the printer
            continue;
        };
        const len = c.s.machine.retract_length;
        if (len > 0) try c.put(k, v, "filament.retract_ratio", try num(arena, n / len), null) else try c.unused(k, v, "the printer has no retraction");
    };
    // Pressure advance only when it is on.
    if (c.get("enable_pressure_advance")) |v| {
        if (!(isTrue(v) orelse true)) try c.put("enable_pressure_advance", v, "filament.pressure_advance", "0", null) else try c.used.put(arena, "enable_pressure_advance", {});
    }
    // The bed temperature of the plate type of the printer (OrcaSlicer).
    if (c.orca) {
        const pk = plateKey(c.s.machine.bed_type);
        if (c.get(pk)) |v| try c.put(pk, v, "filament.bed_temp", v, null);
        const pk0 = try std.fmt.allocPrint(arena, "{s}_initial_layer", .{pk});
        if (c.get(pk0)) |v| try c.put(pk0, v, "filament.first_layer_bed_temp", v, null);
    }
    for ([_][]const u8{ "curr_bed_type", "default_bed_type", "cool_plate_temp", "eng_plate_temp", "hot_plate_temp", "textured_plate_temp", "supertack_plate_temp", "cool_plate_temp_initial_layer", "eng_plate_temp_initial_layer", "hot_plate_temp_initial_layer", "textured_plate_temp_initial_layer", "supertack_plate_temp_initial_layer" }) |k| {
        if (kv.get(k)) |v| if (!c.used.contains(k)) try c.unused(k, v, "zslice uses the bed temperature of the plate type of the printer (machine.bed_type)");
    }

    // The keys with no zslice setting.
    var it = kv.iterator();
    while (it.next()) |e| {
        if (c.used.contains(e.key_ptr.*)) continue;
        try c.rows.append(arena, .{ .kind = .unused, .key = e.key_ptr.*, .value = e.value_ptr.*, .note = whyUnused(e.key_ptr.*) });
    }
    return .{ .format = format, .changes = c.changes.items, .rows = c.rows.items };
}

fn whyUnused(key: []const u8) []const u8 {
    const notes = [_][2][]const u8{
        .{ "top_solid_infill_speed", "zslice has one skin speed (project.skin_speed), from the solid infill speed" },
        .{ "top_surface_speed", "zslice has one skin speed (project.skin_speed), from the solid infill speed" },
        .{ "gap_fill_speed", "zslice prints gap fill at the speed of its feature" },
        .{ "gap_infill_speed", "zslice prints gap fill at the speed of its feature" },
        .{ "small_perimeter_speed", "zslice has no speed for small walls" },
        .{ "perimeter_extrusion_width", "zslice has one line width (project.line_width)" },
        .{ "external_perimeter_extrusion_width", "zslice has one line width (project.line_width)" },
        .{ "infill_extrusion_width", "zslice has one line width (project.line_width)" },
        .{ "solid_infill_extrusion_width", "zslice has one line width (project.line_width)" },
        .{ "top_infill_extrusion_width", "zslice has one line width (project.line_width)" },
        .{ "support_material_extrusion_width", "zslice has one line width (project.line_width)" },
        .{ "outer_wall_line_width", "zslice has one line width (project.line_width)" },
        .{ "inner_wall_line_width", "zslice has one line width (project.line_width)" },
        .{ "sparse_infill_line_width", "zslice has one line width (project.line_width)" },
        .{ "internal_solid_infill_line_width", "zslice has one line width (project.line_width)" },
        .{ "top_surface_line_width", "zslice has one line width (project.line_width)" },
        .{ "support_line_width", "zslice has one line width (project.line_width)" },
    };
    for (notes) |n| if (std.mem.eql(u8, n[0], key)) return n[1];
    const meta = [_][]const u8{ "type", "name", "from", "version", "setting_id", "instantiation", "print_settings_id", "compatible_printers", "compatible_printers_condition", "compatible_prints", "compatible_prints_condition", "notes", "printer_notes", "filament_notes", "print_notes", "filament_vendor", "printer_model", "printer_variant", "printer_vendor", "renamed_from", "is_custom_defined", "description" };
    for (meta) |k| if (std.mem.eql(u8, k, key)) return "preset metadata";
    return "zslice has no such setting";
}

fn convertOne(c: *Ctx, m: Map, raw: []const u8) Allocator.Error!void {
    const arena = c.arena;
    const v = first(raw);
    switch (m.conv) {
        .number => {
            const n = parseNum(v) orelse return c.unused(m.key, raw, "not a number");
            // A filament max flow of 0 is "no limit" in PrusaSlicer.
            if (n == 0 and std.mem.eql(u8, m.name, "filament.max_flow")) return c.unused(m.key, raw, "0 is no limit: zslice keeps its value");
            if (n <= 0 and std.mem.eql(u8, m.name, "machine.chamber_temp")) return c.unused(m.key, raw, "no chamber temperature");
            try c.put(m.key, raw, m.name, try num(arena, n), null);
        },
        .count => {
            const n = parseNum(v) orelse return c.unused(m.key, raw, "not a number");
            try c.put(m.key, raw, m.name, try num(arena, @round(@max(0, n))), null);
        },
        .percent => {
            const t = std.mem.trim(u8, v, " %");
            const n = parseNum(t) orelse return c.unused(m.key, raw, "not a number");
            try c.put(m.key, raw, m.name, try num(arena, n / 100), null);
        },
        .ratio => {
            const pct = std.mem.endsWith(u8, std.mem.trim(u8, v, " "), "%");
            const n = parseNum(std.mem.trim(u8, v, " %")) orelse return c.unused(m.key, raw, "not a number");
            try c.put(m.key, raw, m.name, try num(arena, if (pct) n / 100 else n), null);
        },
        .speed => {
            const mm = c.mmPerS(v, m.of, 0) orelse return c.unused(m.key, raw, "not a speed");
            // 0 is "the speed of the feature" or "no limit" in PrusaSlicer.
            if (mm <= 0) return c.unused(m.key, raw, "0: zslice keeps its value");
            const near: ?[]const u8 = if (std.mem.endsWith(u8, std.mem.trim(u8, v, " "), "%") and std.mem.startsWith(u8, m.key, "first_layer"))
                "a percentage of the wall speed: zslice has one first layer speed"
            else
                null;
            try c.put(m.key, raw, m.name, try num(arena, mm / c.s.machine.max_speed), near);
        },
        .mm_s => {
            const mm = c.mmPerS(v, m.of, 0) orelse return c.unused(m.key, raw, "not a speed");
            try c.put(m.key, raw, m.name, try num(arena, mm), null);
        },
        .boolean => {
            const b = isTrue(v) orelse return c.unused(m.key, raw, "not 0 or 1");
            try c.put(m.key, raw, m.name, if (b) "true" else "false", null);
        },
        .text => {
            const t = try unescape(arena, v);
            if (t.len == 0) return c.unused(m.key, raw, "empty");
            try c.put(m.key, raw, m.name, t, null);
        },
        .gcode => {
            const t = try unescape(arena, if (std.mem.indexOfScalar(u8, raw, '"') == 0) first(raw) else raw);
            try c.put(m.key, raw, m.name, t, null);
        },
        .negate => {
            const n = parseNum(v) orelse return c.unused(m.key, raw, "not a number");
            try c.put(m.key, raw, m.name, try num(arena, -n), null);
        },
        .width => {
            const t = std.mem.trim(u8, v, " ");
            if (std.mem.endsWith(u8, t, "%")) {
                const p = parseNum(t[0 .. t.len - 1]) orelse return c.unused(m.key, raw, "not a number");
                // The base of the percentage: the key `of`, or the layer
                // height (PrusaSlicer) or the nozzle (OrcaSlicer).
                const b: f64 = if (m.of.len > 0)
                    (if (c.number(m.of)) |x| x else if (std.mem.eql(u8, m.of, "layer_height")) c.s.project.layer_height else c.s.project.first_layer_height)
                else if (c.orca)
                    c.s.machine.nozzle_diameter
                else if (std.mem.eql(u8, m.name, "project.support_xy_gap"))
                    (if (c.s.project.line_width > 0) c.s.project.line_width else 1.1 * c.s.machine.nozzle_diameter)
                else
                    c.s.project.layer_height;
                // A first layer width of PrusaSlicer is of the first layer
                // height after the first layer height of the file.
                const base = if (std.mem.eql(u8, m.of, "first_layer_height")) c.s.project.first_layer_height else b;
                return c.put(m.key, raw, m.name, try num(arena, p / 100 * base), null);
            }
            const n = parseNum(t) orelse return c.unused(m.key, raw, "not a number");
            try c.put(m.key, raw, m.name, try num(arena, n), null);
        },
        .angle_from_level => {
            const n = parseNum(v) orelse return c.unused(m.key, raw, "not a number");
            if (n <= 0) return c.unused(m.key, raw, "0 is the automatic angle: zslice keeps its value");
            try c.put(m.key, raw, m.name, try num(arena, 90 - n), null);
        },
        .layers => {
            const n = parseNum(v) orelse return c.unused(m.key, raw, "not a number");
            const lh = c.s.project.layer_height;
            try c.put(m.key, raw, m.name, try num(arena, @round(n / lh)), if (n > 0 and @abs(@round(n / lh) * lh - n) > 0.01) "a whole number of layers" else null);
        },
        .spacing => {
            const n = parseNum(v) orelse return c.unused(m.key, raw, "not a number");
            const w = if (c.s.project.line_width > 0) c.s.project.line_width else 1.1 * c.s.machine.nozzle_diameter;
            // Lines of width w, n mm apart: w / (w + n) of the area.
            try c.put(m.key, raw, m.name, try num(arena, w / (w + @max(0, n))), null);
        },
        .choice => {
            const t = std.mem.trim(u8, v, " \"");
            const hit = lookup(m.choices, t) orelse return c.unused(m.key, raw, "zslice has no such choice");
            // No brim: a brim width of 0.
            if (std.mem.eql(u8, m.key, "brim_type") and std.mem.eql(u8, t, "no_brim")) return c.put(m.key, raw, "project.brim_width", "0", null);
            try c.put(m.key, raw, m.name, hit.to, if (hit.near) "the nearest zslice choice" else null);
        },
    }
}

// ---- tests ----

const testing = std.testing;

fn valueOf(r: Result, name: []const u8) ?[]const u8 {
    for (r.changes) |ch| if (std.mem.eql(u8, ch.name, name)) return ch.value;
    return null;
}

fn rowOf(r: Result, key: []const u8) ?Row {
    for (r.rows) |row| if (std.mem.eql(u8, row.key, key)) return row;
    return null;
}

test "a PrusaSlicer config: percentages, speeds, layers, and the unused keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ini =
        \\# generated by PrusaSlicer 2.8.1
        \\layer_height = 0.2
        \\first_layer_height = 0.25
        \\perimeters = 3
        \\top_solid_layers = 5
        \\top_solid_min_thickness = 0.7
        \\bottom_solid_layers = 3
        \\fill_density = 15%
        \\fill_pattern = gyroid
        \\perimeter_speed = 60
        \\external_perimeter_speed = 50%
        \\infill_speed = 200
        \\solid_infill_speed = 75%
        \\travel_speed = 180
        \\temperature = 215,215
        \\bed_temperature = 60
        \\retract_length = 0.8
        \\extrusion_multiplier = 0.98
        \\support_material = 1
        \\support_material_buildplate_only = 1
        \\support_material_threshold = 40
        \\bed_shape = 0x0,250x0,250x210,0x210
        \\seam_position = aligned
        \\start_gcode = G28 ; home\nG1 Z5
        \\complete_objects = 0
        \\avoid_crossing_curled_overhangs = 0
        \\
    ;
    const base: Settings = .{};
    const r = try read(a, ini, "x.ini", &base);
    try testing.expectEqual(Format.prusa_ini, r.format);
    try testing.expectEqualStrings("0.25", valueOf(r, "project.first_layer_height").?);
    try testing.expectEqualStrings("3", valueOf(r, "project.wall_count").?);
    // 5 layers of 0.2 mm is 1 mm, more than the minimum of 0.7 mm.
    try testing.expectEqualStrings("1", valueOf(r, "project.top_thickness").?);
    try testing.expectEqualStrings("0.6", valueOf(r, "project.bottom_thickness").?);
    try testing.expectEqualStrings("0.15", valueOf(r, "project.infill_density").?);
    try testing.expectEqualStrings("gyroid", valueOf(r, "project.infill_pattern").?);
    // The base speed is machine.max_speed, 150 mm/s.
    try testing.expectEqualStrings("0.4", valueOf(r, "project.inner_wall_speed").?);
    // 50 % of 60 mm/s is 30 mm/s.
    try testing.expectEqualStrings("0.2", valueOf(r, "project.outer_wall_speed").?);
    // 200 mm/s is over the base speed: a clamp.
    try testing.expectEqualStrings("1", valueOf(r, "project.infill_speed").?);
    try testing.expectEqual(Row.Kind.clamp, rowOf(r, "infill_speed").?.kind);
    // 75 % of 200 mm/s is 150 mm/s.
    try testing.expectEqualStrings("1", valueOf(r, "project.skin_speed").?);
    try testing.expectEqualStrings("180", valueOf(r, "machine.travel_speed").?);
    try testing.expectEqualStrings("215", valueOf(r, "filament.nozzle_temp").?);
    try testing.expectEqualStrings("0.98", valueOf(r, "filament.flow_ratio").?);
    try testing.expectEqualStrings("buildplate", valueOf(r, "project.support").?);
    try testing.expectEqualStrings("50", valueOf(r, "project.support_angle").?);
    try testing.expectEqualStrings("250", valueOf(r, "machine.bed_size_x").?);
    try testing.expectEqualStrings("210", valueOf(r, "machine.bed_size_y").?);
    try testing.expectEqualStrings("hidden", valueOf(r, "project.seam").?);
    try testing.expectEqualStrings("G28 ; home\nG1 Z5", valueOf(r, "machine.start_gcode").?);
    try testing.expectEqualStrings("by_layer", valueOf(r, "project.print_sequence").?);
    try testing.expectEqual(Row.Kind.unused, rowOf(r, "avoid_crossing_curled_overhangs").?.kind);
    // Each change loads.
    var s = base;
    for (r.changes) |ch| try s.set(ch.name, ch.value);
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try r.writeReport(&aw.writer);
    try testing.expect(std.mem.startsWith(u8, aw.written(), "format\tPrusaSlicer config\n"));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "clamp\tinfill_speed\t200\tproject.infill_speed\t1\t1.3333\n") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "unused\tavoid_crossing_curled_overhangs\t0\tzslice has no such setting\n") != null);
}

test "an OrcaSlicer preset: lists, a printer speed limit as the base, and the plate temperature" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json =
        \\{ "type": "process", "inherits": "0.20mm Standard @BBL X1C",
        \\  "wall_loops": "3", "sparse_infill_density": "20%", "sparse_infill_pattern": "zig-zag",
        \\  "outer_wall_speed": "200", "inner_wall_speed": "300",
        \\  "machine_max_speed_x": ["500", "200"], "machine_max_speed_y": ["400", "200"],
        \\  "nozzle_temperature": ["220"], "textured_plate_temp": ["65"], "hot_plate_temp": ["55"],
        \\  "line_width": "105%", "support_threshold_angle": "30", "enable_support": "1" }
    ;
    const base: Settings = .{};
    const r = try read(a, json, "p.json", &base);
    try testing.expectEqual(Format.orca_json, r.format);
    try testing.expectEqualStrings("400", valueOf(r, "machine.max_speed").?);
    try testing.expectEqualStrings("0.5", valueOf(r, "project.outer_wall_speed").?);
    try testing.expectEqualStrings("0.75", valueOf(r, "project.inner_wall_speed").?);
    try testing.expectEqualStrings("zigzag", valueOf(r, "project.infill_pattern").?);
    try testing.expectEqualStrings("220", valueOf(r, "filament.nozzle_temp").?);
    // The default plate of zslice is the textured PEI plate.
    try testing.expectEqualStrings("65", valueOf(r, "filament.bed_temp").?);
    try testing.expectEqual(Row.Kind.unused, rowOf(r, "hot_plate_temp").?.kind);
    // 105 % of the 0.4 mm nozzle.
    try testing.expectEqualStrings("0.42", valueOf(r, "project.line_width").?);
    try testing.expectEqualStrings("60", valueOf(r, "project.support_angle").?);
    try testing.expectEqual(Row.Kind.unused, rowOf(r, "inherits").?.kind);
}

test "the retraction of the travels goes to the printer, and combing to its mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base: Settings = .{};
    const json =
        \\{ "type": "machine", "z_hop": ["0.4"], "z_hop_types": ["Auto Lift"], "wipe": ["1"],
        \\  "wipe_distance": ["2"], "retract_when_changing_layer": ["1"],
        \\  "retraction_minimum_travel": ["1"], "reduce_crossing_wall": "0" }
    ;
    const r = try read(a, json, "m.json", &base);
    try testing.expectEqualStrings("0.4", valueOf(r, "machine.z_hop").?);
    try testing.expectEqualStrings("true", valueOf(r, "machine.z_hop_only_crossing").?);
    try testing.expectEqualStrings("true", valueOf(r, "machine.retract_wipe").?);
    try testing.expectEqualStrings("2", valueOf(r, "machine.retract_wipe_distance").?);
    try testing.expectEqualStrings("true", valueOf(r, "machine.retract_layer_change").?);
    try testing.expectEqualStrings("1", valueOf(r, "machine.retract_min_travel").?);
    try testing.expectEqualStrings("off", valueOf(r, "project.combing_mode").?);
    const ini =
        \\retract_lift = 0.6
        \\retract_before_travel = 2
        \\retract_layer_change = 0
        \\wipe = 0
        \\avoid_crossing_perimeters = 1
        \\
    ;
    const p = try read(a, ini, "p.ini", &base);
    try testing.expectEqualStrings("0.6", valueOf(p, "machine.z_hop").?);
    try testing.expectEqualStrings("2", valueOf(p, "machine.retract_min_travel").?);
    try testing.expectEqualStrings("false", valueOf(p, "machine.retract_layer_change").?);
    try testing.expectEqualStrings("false", valueOf(p, "machine.retract_wipe").?);
    try testing.expectEqualStrings("all", valueOf(p, "project.combing_mode").?);
}

test "a config bundle reads the presets that it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ini =
        \\[print:Fine]
        \\layer_height = 0.1
        \\[print:Draft]
        \\layer_height = 0.3
        \\[filament:PLA]
        \\temperature = 205
        \\[presets]
        \\print = Draft
        \\filament = PLA
        \\
    ;
    const base: Settings = .{};
    const r = try read(a, ini, "bundle.ini", &base);
    try testing.expectEqualStrings("0.3", valueOf(r, "project.layer_height").?);
    try testing.expectEqualStrings("205", valueOf(r, "filament.nozzle_temp").?);
}

test "a Cura profile export" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const global =
        \\[general]
        \\version = 4
        \\name = Mine
        \\definition = ultimaker_s5
        \\
        \\[metadata]
        \\type = quality_changes
        \\
        \\[values]
        \\layer_height = 0.15
        \\infill_sparse_density = 25
        \\
    ;
    const extruder =
        \\[general]
        \\version = 4
        \\name = Mine
        \\
        \\[metadata]
        \\type = quality_changes
        \\position = 0
        \\
        \\[values]
        \\speed_wall_0 = 300
        \\
    ;
    var zip: Writer.Allocating = .init(a);
    try zipfile.write(a, &zip.writer, &.{
        .{ .name = "custom_global", .data = @constCast(global) },
        .{ .name = "custom_extruder_1", .data = @constCast(extruder) },
    });
    const base: Settings = .{};
    const r = try read(a, zip.written(), "Mine.curaprofile", &base);
    try testing.expectEqual(Format.curaprofile, r.format);
    try testing.expectEqualStrings("0.15", valueOf(r, "project.layer_height").?);
    try testing.expectEqualStrings("0.25", valueOf(r, "project.infill_density").?);
    try testing.expectEqualStrings("1", valueOf(r, "project.outer_wall_speed").?);
    try testing.expectEqual(Row.Kind.clamp, rowOf(r, "speed_wall_0").?.kind);
}

test "a file that is not a profile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const base: Settings = .{};
    try testing.expectError(error.NotProfile, read(arena_state.allocator(), "solid cube\nfacet normal 0 0 1\n", "x.stl", &base));
}
