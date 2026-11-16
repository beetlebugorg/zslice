//! Import of Cura profiles into zslice profiles.
//!
//! Cura keeps the settings of a printer in a "stack" of layers. From the
//! bottom: the machine definition (JSON, with an `inherits` chain), the
//! machine changes, the quality, the quality changes (INI `.inst.cfg`
//! files), and the material (XML `.fdm_material`). A higher layer replaces
//! the values of a lower layer.
//!
//! The importer reads a stack folder in the layout of the printdeck
//! profiles (a `cura.json` that names the files of each layer, see
//! printdeck/profiles/README.md), and writes zslice profiles:
//!
//! - one machine profile, from the definition chain and the machine
//!   changes,
//! - one filament profile for each material,
//! - one project profile for each quality profile.
//!
//! Conversions:
//!
//! - Percentages (infill density, fan speed) become ratios.
//! - Speeds in mm/s become ratios of `machine.max_speed`. The importer sets
//!   `max_speed` to the highest print speed of all quality profiles, so the
//!   print speeds stay the same.
//! - Cura settings that are per quality profile in Cura but per machine or
//!   per filament in zslice (travel speed, retraction, cooling) go in a
//!   `[machine]` or `[filament]` table of the project profile, so that each
//!   project keeps its own values.
//! - G-code variables get their zslice names (see `gcode_vars`).
//! - A Cura value that is an expression (it starts with "=") is not
//!   imported.
//!
//! Each Cura setting that has no zslice setting goes in a comment at the end
//! of the profile, so the user can see what is not imported.
//!
//! The core does no file I/O, so the importer reads files through a
//! `Source` callback.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Source = struct {
    ctx: ?*anyopaque = null,
    /// Returns the bytes of the file at `path` (relative to the stack
    /// folder), allocated in `arena`, or null.
    read: *const fn (ctx: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const u8,
};

pub const Output = struct {
    /// "machine", "filament", or "project".
    group: []const u8,
    /// The file name, without ".toml".
    name: []const u8,
    text: []const u8,
};

pub const Diagnostic = struct {
    file: []const u8 = "",
    message: []const u8 = "",
};

pub const Error = error{ MissingFile, BadFile, OutOfMemory, WriteFailed };

/// A Cura key and the zslice setting that it becomes.
const Map = struct {
    cura: []const u8,
    /// The zslice group of the setting. The project profile writes a setting
    /// of another group in a table of that group.
    group: []const u8,
    key: []const u8,
    conv: Conv = .copy,
};

const Conv = enum {
    copy,
    /// A percentage that becomes a ratio.
    percent,
    /// A speed in mm/s that becomes a ratio of machine.max_speed.
    speed,
    /// A Cura bool (True or False).
    boolean,
    /// A G-code text with Cura variables.
    gcode,
    /// infill_pattern: lines or grid.
    infill_pattern,
    /// z_seam_type.
    seam,
    /// support_type.
    support_type,
};

const machine_map = [_]Map{
    .{ .cura = "machine_width", .group = "machine", .key = "bed_size_x" },
    .{ .cura = "machine_depth", .group = "machine", .key = "bed_size_y" },
    .{ .cura = "machine_height", .group = "machine", .key = "max_height" },
    .{ .cura = "machine_nozzle_size", .group = "machine", .key = "nozzle_diameter" },
    .{ .cura = "machine_start_gcode", .group = "machine", .key = "start_gcode", .conv = .gcode },
    .{ .cura = "machine_end_gcode", .group = "machine", .key = "end_gcode", .conv = .gcode },
};

const project_map = [_]Map{
    .{ .cura = "layer_height", .group = "project", .key = "layer_height" },
    .{ .cura = "layer_height_0", .group = "project", .key = "first_layer_height" },
    .{ .cura = "line_width", .group = "project", .key = "line_width" },
    .{ .cura = "wall_line_count", .group = "project", .key = "wall_count" },
    .{ .cura = "top_bottom_thickness", .group = "project", .key = "top_thickness" },
    .{ .cura = "top_bottom_thickness", .group = "project", .key = "bottom_thickness" },
    .{ .cura = "top_thickness", .group = "project", .key = "top_thickness" },
    .{ .cura = "bottom_thickness", .group = "project", .key = "bottom_thickness" },
    .{ .cura = "infill_sparse_density", .group = "project", .key = "infill_density", .conv = .percent },
    .{ .cura = "infill_pattern", .group = "project", .key = "infill_pattern", .conv = .infill_pattern },
    .{ .cura = "ironing_enabled", .group = "project", .key = "ironing", .conv = .boolean },
    .{ .cura = "z_seam_type", .group = "project", .key = "seam", .conv = .seam },
    .{ .cura = "support_type", .group = "project", .key = "support", .conv = .support_type },
    .{ .cura = "support_angle", .group = "project", .key = "support_angle" },
    .{ .cura = "support_infill_rate", .group = "project", .key = "support_density", .conv = .percent },
    .{ .cura = "support_xy_distance", .group = "project", .key = "support_xy_gap" },
    .{ .cura = "skirt_line_count", .group = "project", .key = "skirt_loops" },
    .{ .cura = "skirt_gap", .group = "project", .key = "skirt_distance" },
    .{ .cura = "brim_width", .group = "project", .key = "brim_width" },
    .{ .cura = "retraction_min_travel", .group = "project", .key = "retract_min_travel" },
    .{ .cura = "retraction_hop", .group = "project", .key = "z_hop" },
    .{ .cura = "speed_wall_0", .group = "project", .key = "outer_wall_speed", .conv = .speed },
    .{ .cura = "speed_wall_x", .group = "project", .key = "inner_wall_speed", .conv = .speed },
    .{ .cura = "speed_topbottom", .group = "project", .key = "skin_speed", .conv = .speed },
    .{ .cura = "speed_infill", .group = "project", .key = "infill_speed", .conv = .speed },
    .{ .cura = "speed_layer_0", .group = "project", .key = "first_layer_speed", .conv = .speed },
    .{ .cura = "speed_travel", .group = "machine", .key = "travel_speed" },
    .{ .cura = "retraction_amount", .group = "machine", .key = "retract_length" },
    .{ .cura = "retraction_speed", .group = "machine", .key = "retract_speed" },
    .{ .cura = "cool_min_layer_time", .group = "filament", .key = "min_layer_time" },
    .{ .cura = "cool_min_speed", .group = "filament", .key = "min_speed" },
    .{ .cura = "cool_fan_speed", .group = "filament", .key = "fan_speed", .conv = .percent },
    .{ .cura = "cool_fan_speed_max", .group = "filament", .key = "fan_max_speed", .conv = .percent },
    .{ .cura = "cool_min_layer_time_fan_speed_max", .group = "filament", .key = "fan_boost_time" },
    .{ .cura = "material_print_temperature", .group = "filament", .key = "nozzle_temp" },
    .{ .cura = "material_print_temperature_layer_0", .group = "filament", .key = "first_layer_nozzle_temp" },
    .{ .cura = "material_bed_temperature", .group = "filament", .key = "bed_temp" },
    .{ .cura = "material_flow", .group = "filament", .key = "flow_ratio", .conv = .percent },
    .{ .cura = "xy_offset", .group = "filament", .key = "xy_offset" },
    .{ .cura = "hole_xy_offset", .group = "filament", .key = "hole_xy_offset" },
    .{ .cura = "xy_offset_layer_0", .group = "project", .key = "first_layer_xy_offset" },
};

/// The speeds of a quality profile. The speeds that are not set explicitly
/// follow speed_print in Cura, so they get its value.
const speed_keys = [_][]const u8{ "speed_print", "speed_wall_0", "speed_wall_x", "speed_topbottom", "speed_infill" };

/// Cura G-code variables and their zslice names.
const gcode_vars = [_][2][]const u8{
    .{ "material_print_temperature", "nozzle_temp" },
    .{ "material_print_temperature_layer_0", "first_layer_nozzle_temp" },
    .{ "material_bed_temperature", "bed_temp" },
    .{ "material_bed_temperature_layer_0", "bed_temp" },
    .{ "material_standby_temperature", "standby_temp" },
    .{ "layer_height", "layer_height" },
    .{ "layer_height_0", "first_layer_height" },
    .{ "speed_layer_0", "first_layer_speed" },
    .{ "machine_nozzle_size", "nozzle_diameter" },
    .{ "material_diameter", "filament_diameter" },
    .{ "material_name", "filament_name" },
    .{ "jobname", "job_name" },
};

/// A value from a Cura file, with the file it came from.
const Value = struct { text: []const u8, from: []const u8 };

/// The values of a stack, by Cura key. A later put replaces an earlier one.
const Values = std.StringArrayHashMapUnmanaged(Value);

pub fn importStack(arena: Allocator, src: Source, diag: *Diagnostic) Error![]Output {
    const cura_json = try readFile(arena, src, "cura.json", diag);
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, cura_json, .{}) catch return bad(diag, "cura.json", "not valid JSON");
    const version = str(root, "cura") orelse "?";
    var outputs: std.ArrayList(Output) = .empty;

    // The machine: the definition chain, then the machine changes.
    var machine: Values = .empty;
    const machine_def = str(root, "machine") orelse return bad(diag, "cura.json", "no \"machine\"");
    const machine_name = try loadDefinition(arena, src, machine_def, &machine, diag);
    if (str(root, "extruder")) |ext| _ = try loadDefinition(arena, src, ext, &machine, diag);
    if (str(root, "definition_changes")) |f| try loadIni(arena, src, f, &machine, diag);
    if (str(root, "definition_changes_extruder")) |f| try loadIni(arena, src, f, &machine, diag);

    // The quality profiles, each with its own stack.
    var profiles: std.ArrayList(struct { name: []const u8, values: Values }) = .empty;
    if (root.object.get("profiles")) |ps| if (ps == .object) {
        var it = ps.object.iterator();
        while (it.next()) |entry| {
            // In Cura, the definition values are the base of each quality
            // profile, and the quality files replace them.
            var values = try machine.clone(arena);
            for ([_][]const u8{ "quality", "quality_changes", "quality_changes_extruder" }) |layer| {
                if (str(entry.value_ptr.*, layer)) |f| try loadIni(arena, src, f, &values, diag);
            }
            try profiles.append(arena, .{ .name = entry.key_ptr.*, .values = values });
        }
    };

    // The highest print speed of all profiles is the speed limit of the
    // machine, so that each speed is a ratio of 1 or less.
    var max_speed: f64 = 0;
    for (profiles.items) |p| {
        for (speed_keys) |k| if (p.values.get(k)) |v| if (number(v.text)) |n| {
            max_speed = @max(max_speed, n);
        };
    }

    // The machine profile.
    {
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("# Imported from Cura {s}: machine definition {s}.\n", .{ version, machine_def });
        try w.print("name = {f}\n", .{quote(machine_name)});
        if (max_speed > 0) {
            try w.print("# The highest print speed of the Cura quality profiles. The speeds of\n# the project profiles are ratios of it.\n", .{});
            try w.print("max_speed = {d}\n", .{max_speed});
        }
        // Cura machine_center_is_zero: the G-code origin is the bed
        // center, and zslice places parts from the front left corner.
        if (machine.get("machine_center_is_zero")) |v| if (std.ascii.eqlIgnoreCase(v.text, "true")) {
            const bw = if (machine.get("machine_width")) |x| number(x.text) orelse 0 else 0;
            const bd = if (machine.get("machine_depth")) |x| number(x.text) orelse 0 else 0;
            try w.print("# Cura machine_center_is_zero: the G-code origin is the bed center.\norigin_x = {d}\norigin_y = {d}\n", .{ -bw / 2, -bd / 2 });
        };
        try writeMapped(arena, w, &machine, &machine_map, "machine", max_speed, .machine_keys);
        if (machine.get("material_diameter")) |v| if (number(v.text)) |n| {
            try w.print("\n# The filament diameter of this machine.\n[filament]\ndiameter = {d}\n", .{n});
        };
        try outputs.append(arena, .{ .group = "machine", .name = slug(arena, machine_def), .text = out.written() });
    }

    // One filament profile for each material.
    if (root.object.get("materials")) |ms| if (ms == .object) {
        var it = ms.object.iterator();
        while (it.next()) |entry| {
            const file = str(entry.value_ptr.*, "file") orelse continue;
            const xml = try readFile(arena, src, file, diag);
            const text = try materialProfile(arena, xml, file, version, entry.key_ptr.*);
            try outputs.append(arena, .{ .group = "filament", .name = entry.key_ptr.*, .text = text.text });
        }
    };

    // One project profile for each quality profile.
    for (profiles.items) |*p| {
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("# Imported from Cura {s}: quality profile {s}.\n", .{ version, p.name });
        // Speeds that Cura derives from speed_print.
        if (p.values.get("speed_print")) |sp| {
            for (speed_keys[1..]) |k| if (p.values.get(k) == null) try p.values.put(arena, k, sp);
        }
        // Thickness from layer counts, when Cura gives counts.
        try thicknessFromLayers(arena, &p.values, "top_layers", "top_thickness");
        try thicknessFromLayers(arena, &p.values, "bottom_layers", "bottom_thickness");
        // A brim from a line count.
        if (p.values.get("adhesion_type")) |a| {
            if (std.mem.eql(u8, a.text, "none")) try p.values.put(arena, "skirt_line_count", .{ .text = "0", .from = a.from });
            if (!std.mem.eql(u8, a.text, "brim")) _ = p.values.orderedRemove("brim_width");
            if (std.mem.eql(u8, a.text, "brim") and p.values.get("brim_width") == null) {
                if (p.values.get("brim_line_count")) |n| if (number(n.text)) |count| {
                    const lw = if (machine.get("machine_nozzle_size")) |nz| number(nz.text) orelse 0.4 else 0.4;
                    try p.values.put(arena, "brim_width", .{ .text = try std.fmt.allocPrint(arena, "{d}", .{count * lw}), .from = n.from });
                };
            }
            _ = p.values.orderedRemove("adhesion_type");
        }
        // support_enable and support_type both make zslice project.support.
        if (p.values.get("support_enable")) |en| {
            if (std.ascii.eqlIgnoreCase(en.text, "false")) {
                try p.values.put(arena, "support_type", .{ .text = "off", .from = en.from });
            } else if (p.values.get("support_type") == null) {
                try p.values.put(arena, "support_type", .{ .text = "everywhere", .from = en.from });
            }
            _ = p.values.orderedRemove("support_enable");
        } else {
            // Cura has no support by default: the type alone does not turn
            // it on.
            _ = p.values.orderedRemove("support_type");
        }
        try writeMapped(arena, w, &p.values, &project_map, "project", max_speed, .other_keys);
        try outputs.append(arena, .{ .group = "project", .name = p.name, .text = out.written() });
    }
    return outputs.toOwnedSlice(arena);
}

fn thicknessFromLayers(arena: Allocator, values: *Values, layers_key: []const u8, thickness_key: []const u8) !void {
    if (values.get(thickness_key) != null) return;
    const n = values.get(layers_key) orelse return;
    const count = number(n.text) orelse return;
    const h = if (values.get("layer_height")) |lh| number(lh.text) orelse 0.2 else 0.2;
    try values.put(arena, thickness_key, .{ .text = try std.fmt.allocPrint(arena, "{d}", .{count * h}), .from = n.from });
    _ = values.orderedRemove(layers_key);
}

/// Writes the mapped values of a stack, in the order of the map, then a
/// comment with the values that have no zslice setting.
/// Which values that are not imported to list: the `machine_*` keys (for
/// the machine profile) or the other keys (for a project profile).
const ListFilter = enum { machine_keys, other_keys };

fn writeMapped(arena: Allocator, w: *Writer, values: *const Values, map: []const Map, own_group: []const u8, max_speed: f64, filter: ListFilter) !void {
    var used = std.StringHashMapUnmanaged(void).empty;
    var groups_done: [3][]const u8 = .{ own_group, "", "" };
    // The own group first (no table), then the other groups in tables.
    const order = [_][]const u8{ own_group, "machine", "filament", "project" };
    for (order, 0..) |group, gi| {
        if (gi > 0 and std.mem.eql(u8, group, own_group)) continue;
        var header = gi == 0;
        for (map) |m| {
            if (!std.mem.eql(u8, m.group, group)) continue;
            const v = values.get(m.cura) orelse continue;
            try used.put(arena, m.cura, {});
            if (v.text.len > 0 and v.text[0] == '=') continue; // an expression: listed below
            const text = (try convert(arena, m.conv, v.text, max_speed)) orelse continue;
            if (!header) {
                try w.print("\n[{s}]\n", .{group});
                header = true;
            }
            if (m.conv == .speed) try w.print("# {s} = {s} mm/s in Cura.\n", .{ m.cura, v.text });
            try w.print("{s} = {s}\n", .{ m.key, text });
        }
        _ = &groups_done;
    }
    // The rest, as comments.
    var first = true;
    var it = values.iterator();
    while (it.next()) |e| {
        const is_expr = e.value_ptr.text.len > 0 and e.value_ptr.text[0] == '=';
        if (used.contains(e.key_ptr.*) and !is_expr) continue;
        const machine_key = std.mem.startsWith(u8, e.key_ptr.*, "machine_");
        if (machine_key != (filter == .machine_keys)) continue;
        if (first) {
            try w.writeAll("\n# Cura settings that are not imported (zslice has no such setting yet,\n# or the Cura value is an expression):\n");
            first = false;
        }
        const one_line = std.mem.indexOfScalar(u8, e.value_ptr.text, '\n') == null;
        if (one_line and e.value_ptr.text.len < 60) {
            try w.print("#   {s} = {s}\n", .{ e.key_ptr.*, e.value_ptr.text });
        } else {
            try w.print("#   {s} = (long value)\n", .{e.key_ptr.*});
        }
    }
}

/// Converts a Cura value to the TOML value of a zslice setting, or null if
/// it cannot be converted.
fn convert(arena: Allocator, conv: Conv, text: []const u8, max_speed: f64) !?[]const u8 {
    switch (conv) {
        .copy => {
            if (number(text)) |n| return try std.fmt.allocPrint(arena, "{d}", .{n});
            return null;
        },
        .percent => {
            const n = number(text) orelse return null;
            return try std.fmt.allocPrint(arena, "{d}", .{@min(n / 100.0, 1.0)});
        },
        .speed => {
            const n = number(text) orelse return null;
            if (!(max_speed > 0)) return null;
            return try std.fmt.allocPrint(arena, "{d:.3}", .{@min(n / max_speed, 1.0)});
        },
        .boolean => {
            if (std.ascii.eqlIgnoreCase(text, "true")) return "true";
            if (std.ascii.eqlIgnoreCase(text, "false")) return "false";
            return null;
        },
        .gcode => return try quoteMultiline(arena, try translateGcode(arena, text)),
        .infill_pattern => {
            if (std.mem.eql(u8, text, "lines") or std.mem.eql(u8, text, "zigzag")) return "\"lines\"";
            for ([_][]const u8{ "grid", "triangles", "cubic", "gyroid", "concentric" }) |same| {
                if (std.mem.eql(u8, text, same)) return try std.fmt.allocPrint(arena, "\"{s}\"", .{same});
            }
            for ([_][]const u8{ "cubicsubdiv", "quarter_cubic", "tetrahedral", "octet" }) |like| {
                if (std.mem.eql(u8, text, like)) return try std.fmt.allocPrint(arena, "\"cubic\" # Cura: {s}", .{like});
            }
            // zslice has no such pattern yet: grid is the nearest.
            return try std.fmt.allocPrint(arena, "\"grid\" # Cura: {s}, which zslice has no pattern for yet", .{text});
        },
        .seam => {
            if (std.mem.eql(u8, text, "back")) return "\"rear\"";
            if (std.mem.eql(u8, text, "shortest")) return "\"nearest\"";
            if (std.mem.eql(u8, text, "random")) return "\"random\"";
            if (std.mem.eql(u8, text, "sharpest_corner")) return "\"sharpest\"";
            return null;
        },
        .support_type => {
            if (std.mem.eql(u8, text, "buildplate")) return "\"buildplate\"";
            if (std.mem.eql(u8, text, "everywhere")) return "\"everywhere\"";
            if (std.mem.eql(u8, text, "off")) return "\"off\"";
            return null;
        },
    }
}

/// Replaces the Cura variables in a G-code text with their zslice names.
fn translateGcode(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try out.appendSlice(arena, rest[0..open]);
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
        const key = rest[open + 1 .. close];
        const name = for (gcode_vars) |v| {
            if (std.mem.eql(u8, v[0], key)) break v[1];
        } else key;
        try out.print(arena, "{{{s}}}", .{name});
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

/// A TOML multi-line literal string. If the text has three single quotes,
/// a basic string with escapes is used instead.
fn quoteMultiline(arena: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, "'''") == null) return std.fmt.allocPrint(arena, "'''\n{s}'''", .{text});
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
    return out.items;
}

const Quoted = struct {
    text: []const u8,
    pub fn format(q: Quoted, w: *Writer) Writer.Error!void {
        try w.writeByte('"');
        for (q.text) |c| switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        };
        try w.writeByte('"');
    }
};

fn quote(text: []const u8) Quoted {
    return .{ .text = text };
}

fn number(text: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch null;
}

fn slug(arena: Allocator, text: []const u8) []const u8 {
    const out = arena.alloc(u8, text.len) catch return text;
    for (text, 0..) |c, i| out[i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '-';
    return out;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn bad(diag: *Diagnostic, file: []const u8, message: []const u8) Error {
    diag.* = .{ .file = file, .message = message };
    return error.BadFile;
}

fn readFile(arena: Allocator, src: Source, path: []const u8, diag: *Diagnostic) Error![]const u8 {
    return src.read(src.ctx, arena, path) orelse {
        diag.* = .{ .file = path, .message = "the file is missing" };
        return error.MissingFile;
    };
}

/// Loads a definition and its `inherits` chain, down to (not including)
/// fdmprinter and fdmextruder: those hold the Cura defaults, and zslice has
/// its own. Returns the "name" of the definition.
fn loadDefinition(arena: Allocator, src: Source, id: []const u8, values: *Values, diag: *Diagnostic) Error![]const u8 {
    if (std.mem.eql(u8, id, "fdmprinter") or std.mem.eql(u8, id, "fdmextruder")) return id;
    const path = try std.fmt.allocPrint(arena, "definitions/{s}.def.json", .{id});
    const text = try readFile(arena, src, path, diag);
    const def = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return bad(diag, path, "not valid JSON");
    // The base first, so that this file replaces its values.
    if (str(def, "inherits")) |base| _ = try loadDefinition(arena, src, base, values, diag);
    if (def.object.get("overrides")) |ov| if (ov == .object) {
        var it = ov.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const dv = e.value_ptr.object.get("default_value") orelse continue;
            const t: ?[]const u8 = switch (dv) {
                .string => |s| s,
                .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
                .bool => |b| if (b) "True" else "False",
                else => null,
            };
            if (t) |v| try values.put(arena, e.key_ptr.*, .{ .text = v, .from = path });
        }
    };
    return str(def, "name") orelse id;
}

/// Loads the [values] of a Cura .inst.cfg file. A line that starts with a
/// tab or a space continues the value of the line before it.
fn loadIni(arena: Allocator, src: Source, path: []const u8, values: *Values, diag: *Diagnostic) Error!void {
    const text = try readFile(arena, src, path, diag);
    var section: []const u8 = "";
    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '\t' or line[0] == ' ') {
            if (last) |k| if (std.mem.eql(u8, section, "values")) {
                const v = values.getPtr(k).?;
                v.text = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ v.text, std.mem.trimStart(u8, line, "\t ") });
            };
            continue;
        }
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[] ");
            last = null;
            continue;
        }
        if (line[0] == '#' or line[0] == ';') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, section, "values")) continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        try values.put(arena, key, .{ .text = value, .from = path });
        last = key;
    }
}

/// A filament profile from a Cura material file. Only the settings outside
/// the <machine> blocks are read: those blocks are for other printers.
fn materialProfile(arena: Allocator, xml: []const u8, file: []const u8, version: []const u8, key: []const u8) !struct { text: []const u8 } {
    const top_end = std.mem.indexOf(u8, xml, "<machine>") orelse xml.len;
    const top = xml[0..top_end];
    const brand = tagText(top, "brand") orelse "";
    const material = tagText(top, "material") orelse "";
    const color = tagText(top, "color") orelse "";

    var values: Values = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, top, pos, "setting key=\"")) |at| {
        const ks = at + "setting key=\"".len;
        const ke = std.mem.indexOfScalarPos(u8, top, ks, '"') orelse break;
        const vs = (std.mem.indexOfScalarPos(u8, top, ke, '>') orelse break) + 1;
        const ve = std.mem.indexOfScalarPos(u8, top, vs, '<') orelse break;
        try values.put(arena, top[ks..ke], .{ .text = std.mem.trim(u8, top[vs..ve], " \t\r\n"), .from = file });
        pos = ve;
    }

    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("# Imported from Cura {s}: material {s} ({s}).\n", .{ version, key, file });
    try w.print("name = {f}\n", .{quote(try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ brand, material, color }))});
    if (tagText(top, "color_code")) |cc| if (cc.len == 7 and cc[0] == '#') try w.print("color = \"{s}\"\n", .{cc});
    if (tagText(top, "diameter")) |d| if (number(d)) |n| try w.print("diameter = {d}\n", .{n});
    if (tagText(top, "density")) |d| if (number(d)) |n| try w.print("density = {d}\n", .{n});
    const xml_map = [_][2][]const u8{
        .{ "print temperature", "nozzle_temp" },
        .{ "material_print_temperature_layer_0", "first_layer_nozzle_temp" },
        .{ "heated bed temperature", "bed_temp" },
        .{ "standby temperature", "standby_temp" },
    };
    var used = std.StringHashMapUnmanaged(void).empty;
    for (xml_map) |m| if (values.get(m[0])) |v| if (number(v.text)) |n| {
        try w.print("{s} = {d}\n", .{ m[1], n });
        try used.put(arena, m[0], {});
    };
    // Calibration values of the material, as Cura settings.
    const cura_map = [_][2][]const u8{ .{ "xy_offset", "xy_offset" }, .{ "hole_xy_offset", "hole_xy_offset" } };
    for (cura_map) |m| if (values.get(m[0])) |v| if (number(v.text)) |n| {
        try w.print("{s} = {d}\n", .{ m[1], n });
        try used.put(arena, m[0], {});
    };
    // Shrinkage, as a percentage. The general value applies where there is
    // no value for one direction.
    const general = if (values.get("material_shrinkage_percentage")) |v| number(v.text) else null;
    if (general != null) try used.put(arena, "material_shrinkage_percentage", {});
    for ([_][2][]const u8{ .{ "material_shrinkage_percentage_xy", "shrinkage_xy" }, .{ "material_shrinkage_percentage_z", "shrinkage_z" } }) |m| {
        const pct = if (values.get(m[0])) |v| number(v.text) else general;
        if (pct) |n| try w.print("{s} = {d}\n", .{ m[1], n / 100.0 });
        if (values.get(m[0]) != null) try used.put(arena, m[0], {});
    }
    if (values.get("print cooling")) |v| if (number(v.text)) |n| {
        try w.print("fan_speed = {d}\n", .{@min(n / 100.0, 1.0)});
        try used.put(arena, "print cooling", {});
    };
    var first = true;
    var it = values.iterator();
    while (it.next()) |e| {
        if (used.contains(e.key_ptr.*)) continue;
        if (first) {
            try w.writeAll("\n# Cura material settings that are not imported:\n");
            first = false;
        }
        try w.print("#   {s} = {s}\n", .{ e.key_ptr.*, e.value_ptr.text });
    }
    return .{ .text = out.written() };
}

/// The text of the first <tag>...</tag> in xml.
fn tagText(xml: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const s = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    const e = std.mem.indexOfPos(u8, xml, s, close) orelse return null;
    return std.mem.trim(u8, xml[s..e], " \t\r\n");
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const profile = @import("profile.zig");
const Settings = @import("settings.zig").Settings;

const TestSource = struct {
    files: []const [2][]const u8,
    fn read(ctx: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const u8 {
        _ = arena;
        const self: *const TestSource = @ptrCast(@alignCast(ctx.?));
        for (self.files) |f| if (std.mem.eql(u8, f[0], path)) return f[1];
        return null;
    }
};

test "import a small Cura stack and load the result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: TestSource = .{ .files = &.{
        .{ "cura.json",
        \\{"cura": "5.13.0", "machine": "test_printer", "extruder": "test_extruder",
        \\ "definition_changes": "definition_changes/machine.inst.cfg",
        \\ "profiles": {"pla-standard": {"quality_changes": "q.inst.cfg", "quality_changes_extruder": "q_e0.inst.cfg"}},
        \\ "materials": {"roll-1": {"file": "materials/navy.xml.fdm_material"}}}
        },
        .{ "definitions/test_printer.def.json",
        \\{"name": "Test Printer", "inherits": "fdmprinter", "overrides": {
        \\  "machine_width": {"default_value": 280}, "machine_depth": {"default_value": 280},
        \\  "machine_height": {"default_value": 285}, "machine_heated_bed": {"default_value": true}}}
        },
        .{ "definitions/test_extruder.def.json",
        \\{"name": "Extruder", "inherits": "fdmextruder", "overrides": {
        \\  "machine_nozzle_size": {"default_value": 0.5}, "material_diameter": {"default_value": 2.85}}}
        },
        .{ "definition_changes/machine.inst.cfg",
        \\[general]
        \\name = changes
        \\[values]
        \\machine_start_gcode = ; start
        \\  PRINT_START BED={material_bed_temperature_layer_0} LAYER={layer_height_0}
        \\  M117 {jobname}
        \\machine_acceleration = 3000
        },
        .{ "q.inst.cfg",
        \\[values]
        \\layer_height = 0.2
        \\layer_height_0 = 0.25
        \\adhesion_type = brim
        \\support_enable = True
        \\support_type = buildplate
        \\infill_pattern = gyroid
        \\top_layers = 4
        \\speed_print = 50
        \\retraction_combing = noskin
        },
        .{ "q_e0.inst.cfg",
        \\[values]
        \\infill_sparse_density = 20
        \\speed_wall_0 = 25
        \\speed_layer_0 = 18
        \\retraction_amount = 1.5
        \\brim_line_count = 6
        \\cool_min_layer_time = 10
        \\wall_line_count = =3 if layer_height < 0.2 else 2
        },
        .{ "materials/navy.xml.fdm_material",
        \\<fdmmaterial><metadata><name><brand>Acme</brand><material>PLA</material><color>Navy</color></name></metadata>
        \\<properties><density>1.24</density><diameter>2.85</diameter></properties>
        \\<settings><setting key="print temperature">210</setting><setting key="heated bed temperature">60</setting>
        \\<setting key="standby temperature">160</setting><cura:setting key="xy_offset">0.144</cura:setting>
        \\<machine><setting key="print temperature">200</setting></machine></settings></fdmmaterial>
        },
    } };
    var diag: Diagnostic = .{};
    const outs = try importStack(a, .{ .ctx = &files, .read = TestSource.read }, &diag);
    try testing.expectEqual(@as(usize, 3), outs.len);

    // Each output loads as a zslice profile, and the values are right.
    var s: Settings = .{};
    var pd: profile.Diagnostic = .{};
    for (outs) |o| {
        const g = std.meta.stringToEnum(profile.Group, o.group).?;
        profile.apply(a, &s, g, o.name, o.text, null, &pd) catch |e| {
            std.debug.print("{s}: line {d}: {s}\n{s}\n", .{ o.name, pd.line, pd.message, o.text });
            return e;
        };
    }
    try testing.expectEqual(@as(f64, 280), s.machine.bed_size_x);
    try testing.expectEqual(@as(f64, 0.5), s.machine.nozzle_diameter);
    try testing.expectEqual(@as(f64, 50), s.machine.max_speed);
    try testing.expectEqual(@as(f64, 1.5), s.machine.retract_length);
    try testing.expectEqual(@as(f64, 2.85), s.filament.diameter);
    try testing.expectEqual(@as(f64, 210), s.filament.nozzle_temp); // not the 200 of the machine block
    try testing.expectEqual(@as(f64, 160), s.filament.standby_temp);
    try testing.expectEqual(@as(f64, 10), s.filament.min_layer_time);
    try testing.expectEqual(@as(f64, 0.25), s.project.first_layer_height);
    try testing.expectEqual(@as(f64, 0.2), s.project.infill_density);
    try testing.expectEqual(@as(f64, 0.5), s.project.outer_wall_speed);
    try testing.expectEqual(@as(f64, 3), s.project.brim_width); // 6 lines of 0.5 mm
    try testing.expectApproxEqAbs(@as(f64, 0.8), s.project.top_thickness, 1e-9);
    try testing.expect(std.mem.indexOf(u8, s.machine.start_gcode, "BED={bed_temp} LAYER={first_layer_height}") != null);
    try testing.expect(std.mem.indexOf(u8, s.machine.start_gcode, "M117 {job_name}") != null);
    try testing.expectEqual(@as(u32, 2), s.project.wall_count); // the expression is not imported
    try testing.expectEqual(@import("settings.zig").SupportMode.buildplate, s.project.support);
    // The settings that are not imported are listed.
    const proj = for (outs) |o| {
        if (std.mem.eql(u8, o.group, "project")) break o.text;
    } else unreachable;
    try testing.expect(std.mem.indexOf(u8, proj, "#   retraction_combing = noskin") != null);
    try testing.expect(std.mem.indexOf(u8, proj, "#   wall_line_count = =3") != null);
}
