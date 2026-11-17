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
//!
//! Per-object settings (`partSettings`): a Cura project 3MF keeps the
//! settings of each object in its metadata ("cura:infill_sparse_density").
//! They map to zslice settings with the same table as the profiles, plus
//! the keys that only an object has: the modifier volume flags
//! (`infill_mesh`, `cutting_mesh`, `anti_overhang_mesh`, `support_mesh`),
//! `infill_mesh_order`, `infill_line_distance`, `infill_angles`, and
//! `infill_material_flow`. A value that starts with "=" is a Cura formula:
//! a formula of one constant ("=100", "=False") is read as the constant.
//! Cura measures an infill angle from the Y axis, and zslice from the X
//! axis: a Cura angle a is the zslice angle 90 - a.
//!
//! References (see REFERENCES.md): the Cura profile formats (`.def.json`,
//! `.inst.cfg`, `.xml.fdm_material`) and the Cura setting names; the Cura
//! project 3MF metadata; the infill line distance and the infill angles
//! of CuraEngine.

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
    .{ .cura = "wall_thickness", .group = "project", .key = "wall_thickness" },
    .{ .cura = "zig_zaggify_infill", .group = "project", .key = "infill_connect" },
    .{ .cura = "speed_slowdown_layers", .group = "project", .key = "slow_layers" },
    .{ .cura = "acceleration_wall_0", .group = "project", .key = "outer_wall_accel" },
    .{ .cura = "acceleration_wall_x", .group = "project", .key = "inner_wall_accel" },
    .{ .cura = "acceleration_topbottom", .group = "project", .key = "skin_accel" },
    .{ .cura = "acceleration_infill", .group = "project", .key = "infill_accel" },
    .{ .cura = "acceleration_travel", .group = "project", .key = "travel_accel" },
    .{ .cura = "acceleration_layer_0", .group = "project", .key = "first_layer_accel" },
    .{ .cura = "machine_acceleration", .group = "machine", .key = "max_accel" },
    .{ .cura = "acceleration_enabled", .group = "machine", .key = "accel_control" },
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
    .{ .cura = "retraction_combing_max_distance", .group = "project", .key = "combing_max_distance" },
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
pub const Value = struct { text: []const u8, from: []const u8 };

/// The values of a stack, by Cura key. A later put replaces an earlier one.
pub const Values = std.StringArrayHashMapUnmanaged(Value);

/// A quality profile of a stack, with the values of all its layers.
pub const Profile = struct { name: []const u8, values: Values };

/// A material of a stack, with the text of its file.
pub const Material = struct { key: []const u8, file: []const u8, xml: []const u8 };

/// The values of a stack, before they become zslice profiles.
pub const Stack = struct {
    version: []const u8,
    machine_def: []const u8,
    machine_name: []const u8,
    /// The definition chain, the machine changes, and the variant.
    machine: Values,
    profiles: []Profile,
    materials: []Material,
    /// The highest print speed of all profiles (see `importStack`).
    max_speed: f64,
};

pub const Options = struct {
    /// The speed that the speed ratios of the project profiles relate to.
    /// Null: the highest print speed of the stack, which also becomes
    /// `machine.max_speed`. With a value, the ratios keep all their digits.
    speed_base: ?f64 = null,
};

pub fn importStack(arena: Allocator, src: Source, diag: *Diagnostic) Error![]Output {
    const stack = try resolveStack(arena, src, diag);
    return writeStack(arena, &stack, .{});
}

/// The layers of a quality profile in cura.json, from the bottom. A layer
/// of the extruder comes after the global layer of the same level, so it
/// wins.
const profile_layers = [_][]const u8{
    "quality",         "quality_extruder",
    "intent",          "intent_extruder",
    "quality_changes", "quality_changes_extruder",
    "user",            "user_extruder",
};

/// Reads cura.json and the files that it names, and gives the values of
/// each layer in the order of the Cura stack.
pub fn resolveStack(arena: Allocator, src: Source, diag: *Diagnostic) Error!Stack {
    const cura_json = try readFile(arena, src, "cura.json", diag);
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, cura_json, .{}) catch return bad(diag, "cura.json", "not valid JSON");

    // The machine: the definition chain, the machine changes, then the
    // variant (the nozzle).
    var machine: Values = .empty;
    const machine_def = str(root, "machine") orelse return bad(diag, "cura.json", "no \"machine\"");
    const machine_name = try loadDefinition(arena, src, machine_def, &machine, diag);
    if (str(root, "extruder")) |ext| _ = try loadDefinition(arena, src, ext, &machine, diag);
    if (str(root, "definition_changes")) |f| try loadIni(arena, src, f, &machine, diag);
    if (str(root, "definition_changes_extruder")) |f| try loadIni(arena, src, f, &machine, diag);
    if (str(root, "variant")) |f| try loadIni(arena, src, f, &machine, diag);

    // The quality profiles, each with its own stack.
    var profiles: std.ArrayList(Profile) = .empty;
    if (root.object.get("profiles")) |ps| if (ps == .object) {
        var it = ps.object.iterator();
        while (it.next()) |entry| {
            // In Cura, the definition values are the base of each quality
            // profile, and the quality files replace them.
            var values = try machine.clone(arena);
            // The material of this profile, between the machine and the
            // quality, as in the Cura stack.
            if (str(entry.value_ptr.*, "material")) |f| {
                try materialValues(arena, try readFile(arena, src, f, diag), f, &values);
            }
            for (profile_layers) |layer| {
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

    for (profiles.items) |*p| try prepareProfile(arena, &p.values, &machine);

    var materials: std.ArrayList(Material) = .empty;
    if (root.object.get("materials")) |ms| if (ms == .object) {
        var it = ms.object.iterator();
        while (it.next()) |entry| {
            const file = str(entry.value_ptr.*, "file") orelse continue;
            try materials.append(arena, .{ .key = entry.key_ptr.*, .file = file, .xml = try readFile(arena, src, file, diag) });
        }
    };

    return .{
        .version = str(root, "cura") orelse "?",
        .machine_def = machine_def,
        .machine_name = machine_name,
        .machine = machine,
        .profiles = profiles.items,
        .materials = materials.items,
        .max_speed = max_speed,
    };
}

/// Turns the Cura values of a profile into the values that the map
/// converts: the speeds that follow speed_print, the thickness from layer
/// counts, the brim, and the support.
fn prepareProfile(arena: Allocator, values: *Values, machine: *const Values) Error!void {
    // Speeds that Cura derives from speed_print.
    if (values.get("speed_print")) |sp| {
        for (speed_keys[1..]) |k| if (values.get(k) == null) try values.put(arena, k, sp);
    }
    // Thickness from layer counts, when Cura gives counts.
    try thicknessFromLayers(arena, values, "top_layers", "top_thickness");
    try thicknessFromLayers(arena, values, "bottom_layers", "bottom_thickness");
    // A brim from a line count.
    if (values.get("adhesion_type")) |a| {
        if (std.mem.eql(u8, a.text, "none")) try values.put(arena, "skirt_line_count", .{ .text = "0", .from = a.from });
        if (!std.mem.eql(u8, a.text, "brim")) _ = values.orderedRemove("brim_width");
        if (std.mem.eql(u8, a.text, "brim") and values.get("brim_width") == null) {
            if (values.get("brim_line_count")) |n| if (number(n.text)) |count| {
                const lw = if (machine.get("machine_nozzle_size")) |nz| number(nz.text) orelse 0.4 else 0.4;
                try values.put(arena, "brim_width", .{ .text = try std.fmt.allocPrint(arena, "{d}", .{count * lw}), .from = n.from });
            };
        }
        _ = values.orderedRemove("adhesion_type");
    }
    // support_enable and support_type both make zslice project.support.
    if (values.get("support_enable")) |en| {
        if (std.ascii.eqlIgnoreCase(en.text, "false")) {
            try values.put(arena, "support_type", .{ .text = "off", .from = en.from });
        } else if (values.get("support_type") == null) {
            try values.put(arena, "support_type", .{ .text = "everywhere", .from = en.from });
        }
        _ = values.orderedRemove("support_enable");
    } else {
        // Cura has no support by default: the type alone does not turn
        // it on.
        _ = values.orderedRemove("support_type");
    }
}

/// Writes the zslice profiles of a stack: one machine profile, one
/// filament profile for each material, and one project profile for each
/// quality profile.
pub fn writeStack(arena: Allocator, stack: *const Stack, opts: Options) Error![]Output {
    var outputs: std.ArrayList(Output) = .empty;
    const max_speed = stack.max_speed;
    const speed: SpeedBase = if (opts.speed_base) |b| .{ .base = b, .precise = true } else .{ .base = max_speed, .precise = false };

    // The machine profile.
    {
        const machine = &stack.machine;
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("# Imported from Cura {s}: machine definition {s}.\n", .{ stack.version, stack.machine_def });
        try w.print("name = {f}\n", .{quote(stack.machine_name)});
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
        try writeMapped(arena, w, machine, &machine_map, "machine", speed, .machine_keys);
        if (machine.get("material_diameter")) |v| if (number(v.text)) |n| {
            try w.print("\n# The filament diameter of this machine.\n[filament]\ndiameter = {d}\n", .{n});
        };
        try outputs.append(arena, .{ .group = "machine", .name = slug(arena, stack.machine_def), .text = out.written() });
    }

    // One filament profile for each material.
    for (stack.materials) |m| {
        const text = try materialProfile(arena, m.xml, m.file, stack.version, m.key);
        try outputs.append(arena, .{ .group = "filament", .name = m.key, .text = text.text });
    }

    // One project profile for each quality profile.
    for (stack.profiles) |*p| {
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("# Imported from Cura {s}: quality profile {s}.\n", .{ stack.version, p.name });
        try writeMapped(arena, w, &p.values, &project_map, "project", speed, .other_keys);
        try outputs.append(arena, .{ .group = "project", .name = p.name, .text = out.written() });
    }
    return outputs.toOwnedSlice(arena);
}

/// A Cura key of the maps, the zslice setting that it becomes, and its
/// value in a stack.
pub const Mapping = struct {
    cura: []const u8,
    /// The dotted zslice name, for example "project.layer_height".
    name: []const u8,
    value: Value,
    /// A speed in mm/s, which becomes a ratio of machine.max_speed.
    speed: bool,
    /// The value is a Cura formula (it starts with "="), which the
    /// importer does not import.
    formula: bool,
};

/// The keys of the maps that the machine and profile `p` of a stack have
/// values for, in the order of the maps.
pub fn mappings(arena: Allocator, stack: *const Stack, p: usize) Allocator.Error![]Mapping {
    var list: std.ArrayList(Mapping) = .empty;
    const sources = [_]struct { values: *const Values, map: []const Map }{
        .{ .values = &stack.machine, .map = &machine_map },
        .{ .values = &stack.profiles[p].values, .map = &project_map },
    };
    for (sources) |s| for (s.map) |m| {
        const v = s.values.get(m.cura) orelse continue;
        try list.append(arena, .{
            .cura = m.cura,
            .name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ m.group, m.key }),
            .value = v,
            .speed = m.conv == .speed,
            .formula = v.text.len > 0 and v.text[0] == '=',
        });
    };
    return list.items;
}

/// The Cura keys of the settings in a material file, and the Cura stack
/// keys that they set. A material file can also hold Cura keys as they
/// are (`cura:setting`).
const material_keys = [_][2][]const u8{
    .{ "print temperature", "material_print_temperature" },
    .{ "heated bed temperature", "material_bed_temperature" },
    .{ "standby temperature", "material_standby_temperature" },
    .{ "print cooling", "cool_fan_speed" },
    .{ "retraction amount", "retraction_amount" },
    .{ "retraction speed", "retraction_speed" },
};

/// The settings of a material file outside the <machine> blocks (those
/// blocks are for other printers), by their key in the file.
fn xmlSettings(arena: Allocator, xml: []const u8, file: []const u8) Allocator.Error!Values {
    const top_end = std.mem.indexOf(u8, xml, "<machine>") orelse xml.len;
    const top = xml[0..top_end];
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
    return values;
}

/// Puts the settings of a material file in `values`, with the Cura stack
/// keys.
fn materialValues(arena: Allocator, xml: []const u8, file: []const u8, values: *Values) Allocator.Error!void {
    const settings = try xmlSettings(arena, xml, file);
    var it = settings.iterator();
    while (it.next()) |e| {
        const key = for (material_keys) |mk| {
            if (std.mem.eql(u8, mk[0], e.key_ptr.*)) break mk[1];
        } else e.key_ptr.*;
        // A key with a space is a material key with no Cura stack key.
        if (std.mem.indexOfScalar(u8, key, ' ') != null) continue;
        try values.put(arena, key, e.value_ptr.*);
    }
}

/// A layer count wins over a thickness, as in Cura: CuraEngine prints the
/// count, and Cura makes the count from the thickness only when the count
/// has no value of its own.
fn thicknessFromLayers(arena: Allocator, values: *Values, layers_key: []const u8, thickness_key: []const u8) !void {
    const n = values.get(layers_key) orelse return;
    const count = number(n.text) orelse return;
    const h = if (values.get("layer_height")) |lh| number(lh.text) orelse 0.2 else 0.2;
    try values.put(arena, thickness_key, .{ .text = try std.fmt.allocPrint(arena, "{d}", .{count * h}), .from = n.from });
    _ = values.orderedRemove(layers_key);
}

/// True if a later entry of `map` sets the same zslice setting as entry
/// `mi` with a value that is not an expression.
fn laterValue(values: *const Values, map: []const Map, mi: usize) bool {
    const m = map[mi];
    for (map[mi + 1 ..]) |o| {
        if (!std.mem.eql(u8, o.group, m.group) or !std.mem.eql(u8, o.key, m.key)) continue;
        const v = values.get(o.cura) orelse continue;
        if (v.text.len > 0 and v.text[0] == '=') continue;
        return true;
    }
    return false;
}

/// Writes the mapped values of a stack, in the order of the map, then a
/// comment with the values that have no zslice setting.
/// Which values that are not imported to list: the `machine_*` keys (for
/// the machine profile) or the other keys (for a project profile).
const ListFilter = enum { machine_keys, other_keys };

/// The speed that the speed ratios relate to, and if a ratio keeps all its
/// digits.
const SpeedBase = struct { base: f64, precise: bool };

fn writeMapped(arena: Allocator, w: *Writer, values: *const Values, map: []const Map, own_group: []const u8, speed: SpeedBase, filter: ListFilter) !void {
    var used = std.StringHashMapUnmanaged(void).empty;
    var groups_done: [3][]const u8 = .{ own_group, "", "" };
    // The own group first (no table), then the other groups in tables.
    const order = [_][]const u8{ own_group, "machine", "filament", "project" };
    for (order, 0..) |group, gi| {
        if (gi > 0 and std.mem.eql(u8, group, own_group)) continue;
        var header = gi == 0;
        for (map, 0..) |m, mi| {
            if (!std.mem.eql(u8, m.group, group)) continue;
            const v = values.get(m.cura) orelse continue;
            // Two Cura settings can make one zslice setting (for example
            // top_bottom_thickness and top_thickness): the later one in
            // the map wins, and each key is written once.
            if (laterValue(values, map, mi)) {
                try used.put(arena, m.cura, {});
                continue;
            }
            try used.put(arena, m.cura, {});
            if (v.text.len > 0 and v.text[0] == '=') continue; // an expression: listed below
            const text = (try convert(arena, m.conv, v.text, speed)) orelse continue;
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
fn convert(arena: Allocator, conv: Conv, text: []const u8, speed: SpeedBase) !?[]const u8 {
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
            if (!(speed.base > 0)) return null;
            const ratio = @min(n / speed.base, 1.0);
            if (speed.precise) return try std.fmt.allocPrint(arena, "{d}", .{ratio});
            return try std.fmt.allocPrint(arena, "{d:.3}", .{ratio});
        },
        .boolean => {
            if (std.ascii.eqlIgnoreCase(text, "true")) return "true";
            if (std.ascii.eqlIgnoreCase(text, "false")) return "false";
            return null;
        },
        .gcode => return try quoteMultiline(arena, try translateGcode(arena, text)),
        .infill_pattern => {
            if (std.mem.eql(u8, text, "lines") or std.mem.eql(u8, text, "zigzag")) return "\"lines\"";
            for ([_][]const u8{ "grid", "triangles", "trihexagon", "cubic", "gyroid", "concentric" }) |same| {
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

    const values = try xmlSettings(arena, xml, file);

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

// ---------------------------------------------------------------------------
// Per-object settings of a Cura project 3MF

/// What an object is in a Cura project.
pub const PartRole = enum {
    /// A part that prints.
    normal,
    /// A modifier volume: the infill of the parts inside it gets the
    /// settings of the volume ("Modify settings for infill of other
    /// models" in Cura).
    infill_mesh,
    /// A volume that cuts the parts and prints with its own settings.
    cutting_mesh,
    /// A volume with no support in it.
    anti_overhang_mesh,
    /// A volume that prints as support.
    support_mesh,
};

/// A zslice setting from a Cura key, by its dotted name.
pub const PartSetting = @import("settings.zig").Change;

/// A Cura key that zslice does not use, and why.
pub const Ignored = struct { key: []const u8, value: []const u8, why: []const u8 };

pub const PartSettings = struct {
    role: PartRole = .normal,
    /// `infill_mesh_order`: where two modifier volumes overlap, the one with
    /// the higher order wins.
    order: i32 = 0,
    sets: []const PartSetting = &.{},
    ignored: []const Ignored = &.{},
};

/// The text of a Cura value, with the "=" of a formula of one constant
/// removed. Null for a formula of more than a constant.
fn constantText(text: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len > 0 and t[0] == '=') {
        t = std.mem.trim(u8, t[1..], " \t");
        // A constant: a number, a word, or a list of numbers.
        for (t) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_' or c == '[' or c == ']' or c == ',' or c == ' ';
            if (!ok) return null;
        }
        if (std.mem.indexOfScalar(u8, t, ' ') != null and t[0] != '[') return null;
    }
    return t;
}

fn curaBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

/// The role of an object from its metadata ("cura:infill_mesh" and the
/// other flags), and its `infill_mesh_order`.
pub fn partRole(meta: anytype) struct { role: PartRole, order: i32 } {
    var role: PartRole = .normal;
    var order: i32 = 0;
    for (meta) |m| {
        const key = curaKey(m.key) orelse continue;
        const v = constantText(m.value) orelse continue;
        if (std.mem.eql(u8, key, "infill_mesh_order")) {
            order = std.fmt.parseInt(i32, v, 10) catch order;
            continue;
        }
        const flag = std.meta.stringToEnum(PartRole, key) orelse continue;
        if (flag == .normal) continue;
        if (curaBool(v) orelse false) role = flag;
    }
    return .{ .role = role, .order = order };
}

/// The Cura key of a metadata name: "cura:infill_mesh" is "infill_mesh".
/// Null for a name of another application.
fn curaKey(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "cura:")) return name["cura:".len..];
    return null;
}

/// The zslice infill pattern of a Cura pattern, and a note if it is only
/// the nearest pattern.
fn partPattern(text: []const u8) ?struct { name: []const u8, note: []const u8 } {
    for ([_][]const u8{ "lines", "grid", "triangles", "trihexagon", "cubic", "gyroid", "concentric", "zigzag", "lightning", "honeycomb" }) |same| {
        if (std.mem.eql(u8, text, same)) return .{ .name = same, .note = "" };
    }
    for ([_][]const u8{ "cubicsubdiv", "quarter_cubic", "tetrahedral", "octet" }) |like| {
        if (std.mem.eql(u8, text, like)) return .{ .name = "cubic", .note = "zslice has no such pattern: cubic is the nearest" };
    }
    if (std.mem.eql(u8, text, "cross") or std.mem.eql(u8, text, "cross_3d")) return .{ .name = "grid", .note = "zslice has no such pattern: grid is the nearest" };
    return null;
}

/// The spacing of one line set of a pattern, as a multiple of line width /
/// density. Cura makes infill_line_distance with the same factors.
fn patternFactor(pattern: []const u8) f64 {
    if (std.mem.eql(u8, pattern, "grid")) return 2;
    if (std.mem.eql(u8, pattern, "triangles") or std.mem.eql(u8, pattern, "trihexagon") or std.mem.eql(u8, pattern, "cubic")) return 3;
    return 1;
}

/// The zslice settings of an object from its metadata (`meta`: a slice of
/// entries with `key` and `value`, for example threemf.Meta). `base` gives
/// the layer height (for the layer counts), the line width (for
/// `infill_line_distance`), and the speed limit (for the speeds). The
/// result is allocated in `arena`.
pub fn partSettings(arena: Allocator, meta: anytype, base: *const @import("settings.zig").Settings) Allocator.Error!PartSettings {
    const settings_mod = @import("settings.zig");
    var out: PartSettings = .{};
    const r = partRole(meta);
    out.role = r.role;
    out.order = r.order;
    var sets: std.ArrayList(PartSetting) = .empty;
    var ignored: std.ArrayList(Ignored) = .empty;
    const put = struct {
        fn f(a: Allocator, list: *std.ArrayList(PartSetting), name: []const u8, value: []const u8) Allocator.Error!void {
            for (list.items) |*e| if (std.mem.eql(u8, e.name, name)) {
                e.value = value;
                return;
            };
            try list.append(a, .{ .name = name, .value = value });
        }
    }.f;
    const p = base.project;
    const line_width = if (p.line_width > 0) p.line_width else 1.1 * base.machine.nozzle_diameter;
    var pattern: []const u8 = @tagName(p.infill_pattern);
    var line_distance: ?f64 = null;
    var has_line_count = false;
    for (meta) |m| if (curaKey(m.key)) |k| {
        if (std.mem.eql(u8, k, "wall_line_count")) has_line_count = true;
    };
    // The thickness keys first, so that a layer count replaces them.
    var layer_keys: [2]?f64 = .{ null, null };

    // The quality profile of the part ("zslice:quality" = "draft"): the
    // values that the built-in profile sets, first, so the other settings
    // of the part go over them.
    for (meta) |m| {
        if (!std.mem.eql(u8, m.key, "zslice:quality")) continue;
        const text = @import("profile.zig").builtin(.project, m.value) orelse {
            try ignored.append(arena, .{ .key = m.key, .value = m.value, .why = "not a built-in quality profile" });
            continue;
        };
        var q: settings_mod.Settings = .{};
        var diag: @import("profile.zig").Diagnostic = .{};
        @import("profile.zig").apply(arena, &q, .project, "(part quality)", text, null, &diag) catch {
            try ignored.append(arena, .{ .key = m.key, .value = m.value, .why = "the profile does not load" });
            continue;
        };
        const d: settings_mod.Settings = .{};
        for (@import("settings_meta.zig").all) |sm| {
            if (!std.mem.startsWith(u8, sm.name, "project.")) continue;
            var wa: std.Io.Writer.Allocating = .init(arena);
            @import("app.zig").App.writeSettingOf(q, sm.name, &wa.writer) catch continue;
            var wb: std.Io.Writer.Allocating = .init(arena);
            @import("app.zig").App.writeSettingOf(d, sm.name, &wb.writer) catch continue;
            if (!std.mem.eql(u8, wa.written(), wb.written())) try put(arena, &sets, sm.name, wa.written());
        }
    }
    for (meta) |m| {
        if (std.mem.eql(u8, m.key, "zslice:quality")) continue;
        // A zslice setting of the part ("zslice:project.infill_density"):
        // as it is, if the setting takes the value.
        if (std.mem.startsWith(u8, m.key, "zslice:")) {
            const name = m.key["zslice:".len..];
            var check = base.*;
            check.set(name, m.value) catch {
                try ignored.append(arena, .{ .key = m.key, .value = m.value, .why = "not a zslice setting or not a valid value" });
                continue;
            };
            try put(arena, &sets, name, m.value);
            continue;
        }
        const key = curaKey(m.key) orelse {
            try ignored.append(arena, .{ .key = m.key, .value = m.value, .why = "not a Cura setting" });
            continue;
        };
        const v = constantText(m.value) orelse {
            try ignored.append(arena, .{ .key = key, .value = m.value, .why = "a Cura formula" });
            continue;
        };
        const num = number(v);
        const skip = struct {
            fn f(a: Allocator, list: *std.ArrayList(Ignored), k_: []const u8, v_: []const u8, why: []const u8) Allocator.Error!void {
                try list.append(a, .{ .key = k_, .value = v_, .why = why });
            }
        }.f;
        if (std.meta.stringToEnum(PartRole, key) != null or std.mem.eql(u8, key, "infill_mesh_order")) continue;
        if (std.mem.eql(u8, key, "infill_sparse_density")) {
            const n = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
            try put(arena, &sets, "project.infill_density", try std.fmt.allocPrint(arena, "{d}", .{std.math.clamp(n / 100, 0, 1)}));
        } else if (std.mem.eql(u8, key, "infill_line_distance")) {
            line_distance = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
        } else if (std.mem.eql(u8, key, "infill_pattern")) {
            const pp = partPattern(v) orelse {
                try skip(arena, &ignored, key, v, "zslice has no such pattern");
                continue;
            };
            pattern = pp.name;
            try put(arena, &sets, "project.infill_pattern", pp.name);
            if (pp.note.len > 0) try skip(arena, &ignored, key, v, pp.note);
        } else if (std.mem.eql(u8, key, "infill_angles")) {
            var buf: [settings_mod.max_infill_angles]f64 = undefined;
            const list = settings_mod.infillAngles(v, &buf) catch {
                try skip(arena, &ignored, key, v, "not a list of numbers");
                continue;
            };
            var text: std.ArrayList(u8) = .empty;
            for (list, 0..) |a, i| {
                if (i > 0) try text.append(arena, ',');
                try text.print(arena, "{d}", .{@mod(90 - a, 180)});
            }
            try put(arena, &sets, "project.infill_angles", text.items);
        } else if (std.mem.eql(u8, key, "infill_material_flow")) {
            const n = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
            try put(arena, &sets, "project.infill_flow", try std.fmt.allocPrint(arena, "{d}", .{std.math.clamp(n / 100, 0.1, 3)}));
        } else if (std.mem.eql(u8, key, "zig_zaggify_infill")) {
            const b = curaBool(v) orelse {
                try skip(arena, &ignored, key, v, "not True or False");
                continue;
            };
            try put(arena, &sets, "project.infill_connect", if (b) "true" else "false");
        } else if (std.mem.eql(u8, key, "wall_line_count")) {
            const n = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
            try put(arena, &sets, "project.wall_count", try std.fmt.allocPrint(arena, "{d}", .{@as(u32, @intFromFloat(@max(0, @round(n))))}));
            try put(arena, &sets, "project.wall_thickness", "0");
        } else if (std.mem.eql(u8, key, "wall_thickness")) {
            if (has_line_count) continue; // the count wins, as in Cura
            const n = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
            if (n > 0) {
                try put(arena, &sets, "project.wall_thickness", try std.fmt.allocPrint(arena, "{d}", .{n}));
            } else {
                try put(arena, &sets, "project.wall_count", "0");
                try put(arena, &sets, "project.wall_thickness", "0");
            }
        } else if (std.mem.eql(u8, key, "top_layers") or std.mem.eql(u8, key, "bottom_layers")) {
            const n = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
            layer_keys[@intFromBool(key[0] == 'b')] = @max(0, @round(n));
        } else if (std.mem.eql(u8, key, "top_bottom_thickness") or std.mem.eql(u8, key, "top_thickness") or std.mem.eql(u8, key, "bottom_thickness")) {
            const n = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
            const text = try std.fmt.allocPrint(arena, "{d}", .{@max(0, n)});
            if (key[0] == 't') try put(arena, &sets, "project.top_thickness", text);
            if (key[0] == 'b' or key[3] == '_' and key[4] == 'b') try put(arena, &sets, "project.bottom_thickness", text);
        } else if (std.mem.eql(u8, key, "initial_bottom_layers")) {
            // The same count as bottom_layers: zslice does the same.
            const same = for (meta) |o| {
                const ok = curaKey(o.key) orelse continue;
                if (!std.mem.eql(u8, ok, "bottom_layers")) continue;
                const ov = constantText(o.value) orelse break false;
                break std.mem.eql(u8, ov, v);
            } else false;
            if (same) continue;
            try skip(arena, &ignored, key, v, "zslice uses the bottom thickness on the bed too");
        } else if (std.mem.eql(u8, key, "gradual_infill_steps")) {
            if (num != null and num.? == 0) continue; // the zslice default
            try skip(arena, &ignored, key, v, "zslice has no gradual infill");
        } else if (std.mem.eql(u8, key, "infill_wipe_dist")) {
            if (num != null and num.? == 0) continue; // the zslice default
            try skip(arena, &ignored, key, v, "zslice has no infill wipe");
        } else if (std.mem.eql(u8, key, "infill_overlap")) {
            const n = num orelse {
                try skip(arena, &ignored, key, v, "not a number");
                continue;
            };
            try put(arena, &sets, "project.infill_overlap", try std.fmt.allocPrint(arena, "{d}", .{std.math.clamp(n / 100, 0, 1)}));
        } else {
            // The keys of the profile table.
            const m_ = for (project_map) |e| {
                if (std.mem.eql(u8, e.cura, key)) break e;
            } else {
                try skip(arena, &ignored, key, v, "zslice has no such setting yet");
                continue;
            };
            const name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ m_.group, m_.key });
            if (!settings_mod.isLayerSetting(name)) {
                try skip(arena, &ignored, key, v, "zslice keeps this setting for the whole plate");
                continue;
            }
            const value: ?[]const u8 = switch (m_.conv) {
                .speed => if (num) |n| try std.fmt.allocPrint(arena, "{d}", .{std.math.clamp(n / base.machine.max_speed, 0.01, 1)}) else null,
                .percent => if (num) |n| try std.fmt.allocPrint(arena, "{d}", .{std.math.clamp(n / 100, 0, 1)}) else null,
                .boolean => if (curaBool(v)) |b| (if (b) "true" else "false") else null,
                .copy => if (num) |n| try std.fmt.allocPrint(arena, "{d}", .{n}) else null,
                .seam => (try convert(arena, .seam, v, .{ .base = 0, .precise = false })),
                else => null,
            };
            const text = value orelse {
                try skip(arena, &ignored, key, v, "a value zslice cannot read");
                continue;
            };
            // The seam conversion gives a TOML string.
            try put(arena, &sets, name, std.mem.trim(u8, text, "\""));
        }
    }
    if (layer_keys[0]) |n| try put(arena, &sets, "project.top_thickness", try std.fmt.allocPrint(arena, "{d}", .{n * p.layer_height}));
    if (layer_keys[1]) |n| try put(arena, &sets, "project.bottom_thickness", try std.fmt.allocPrint(arena, "{d}", .{n * p.layer_height}));
    // A line distance replaces the density, as in Cura.
    if (line_distance) |d| if (d > 0) {
        const density = std.math.clamp(line_width * patternFactor(pattern) / d, 0.001, 1);
        try put(arena, &sets, "project.infill_density", try std.fmt.allocPrint(arena, "{d}", .{density}));
    } else {
        try put(arena, &sets, "project.infill_density", "0");
    };
    out.sets = sets.items;
    out.ignored = ignored.items;
    return out;
}

/// Applies the settings of a part to `s`. Returns the first setting that
/// zslice refuses, or null.
pub fn applyPart(s: *@import("settings.zig").Settings, part: PartSettings) ?PartSetting {
    for (part.sets) |e| s.set(e.name, e.value) catch return e;
    return null;
}

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
        .{
            "cura.json",
            \\{"cura": "5.13.0", "machine": "test_printer", "extruder": "test_extruder",
            \\ "definition_changes": "definition_changes/machine.inst.cfg",
            \\ "profiles": {"pla-standard": {"quality_changes": "q.inst.cfg", "quality_changes_extruder": "q_e0.inst.cfg"}},
            \\ "materials": {"roll-1": {"file": "materials/navy.xml.fdm_material"}}}
        },
        .{
            "definitions/test_printer.def.json",
            \\{"name": "Test Printer", "inherits": "fdmprinter", "overrides": {
            \\  "machine_width": {"default_value": 280}, "machine_depth": {"default_value": 280},
            \\  "machine_height": {"default_value": 285}, "machine_heated_bed": {"default_value": true}}}
        },
        .{
            "definitions/test_extruder.def.json",
            \\{"name": "Extruder", "inherits": "fdmextruder", "overrides": {
            \\  "machine_nozzle_size": {"default_value": 0.5}, "material_diameter": {"default_value": 2.85}}}
        },
        .{
            "definition_changes/machine.inst.cfg",
            \\[general]
            \\name = changes
            \\[values]
            \\machine_start_gcode = ; start
            \\  PRINT_START BED={material_bed_temperature_layer_0} LAYER={layer_height_0}
            \\  M117 {jobname}
            \\machine_acceleration = 3000
        },
        .{
            "q.inst.cfg",
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
        .{
            "q_e0.inst.cfg",
            \\[values]
            \\infill_sparse_density = 20
            \\speed_wall_0 = 25
            \\speed_layer_0 = 18
            \\retraction_amount = 1.5
            \\brim_line_count = 6
            \\cool_min_layer_time = 10
            \\wall_line_count = =3 if layer_height < 0.2 else 2
        },
        .{
            "materials/navy.xml.fdm_material",
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

test "Cura object settings: a grille window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const E = struct { key: []const u8, value: []const u8 };
    const meta = [_]E{
        .{ .key = "cura:infill_mesh", .value = "=True" },
        .{ .key = "cura:infill_mesh_order", .value = "=1" },
        .{ .key = "cura:wall_thickness", .value = "=0" },
        .{ .key = "cura:wall_line_count", .value = "=0" },
        .{ .key = "cura:top_bottom_thickness", .value = "=0" },
        .{ .key = "cura:top_layers", .value = "=0" },
        .{ .key = "cura:bottom_layers", .value = "0" },
        .{ .key = "cura:initial_bottom_layers", .value = "=2" },
        .{ .key = "cura:zig_zaggify_infill", .value = "=False" },
        .{ .key = "cura:infill_wipe_dist", .value = "=0" },
        .{ .key = "cura:speed_infill", .value = "=20" },
        .{ .key = "cura:infill_material_flow", .value = "=110" },
        .{ .key = "cura:infill_pattern", .value = "lines" },
        .{ .key = "cura:infill_sparse_density", .value = "=16.67" },
        .{ .key = "cura:infill_angles", .value = "[90,90,90,0,0,0]" },
        .{ .key = "cura:gradual_infill_steps", .value = "=0" },
        .{ .key = "cura:magic_spiralize", .value = "=infill_sparse_density > 50" },
        .{ .key = "cura:skin_monotonic", .value = "True" },
    };
    var base: Settings = .{};
    base.machine.max_speed = 200;
    base.project.layer_height = 0.25;
    const ps = try partSettings(arena, &meta, &base);
    try testing.expectEqual(PartRole.infill_mesh, ps.role);
    try testing.expectEqual(@as(i32, 1), ps.order);
    var s = base;
    try testing.expect(applyPart(&s, ps) == null);
    try testing.expectEqual(@as(u32, 0), s.project.wall_count);
    try testing.expectEqual(@as(f64, 0), s.project.wall_thickness);
    try testing.expectEqual(@as(f64, 0), s.project.top_thickness);
    try testing.expectEqual(@as(f64, 0), s.project.bottom_thickness);
    try testing.expect(!s.project.infill_connect);
    try testing.expectApproxEqAbs(@as(f64, 0.1), s.project.infill_speed, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.1), s.project.infill_flow, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.1667), s.project.infill_density, 1e-9);
    try testing.expectEqual(@import("settings.zig").InfillPattern.lines, s.project.infill_pattern);
    // Cura measures from the Y axis.
    try testing.expectEqualStrings("0,0,0,90,90,90", s.project.infill_angles);
    _ = try s.resolve();
    // The formula, the key with no zslice setting, and the one with no
    // separate setting are listed.
    var found: usize = 0;
    for (ps.ignored) |ig| {
        if (std.mem.eql(u8, ig.key, "magic_spiralize")) found += 1;
        if (std.mem.eql(u8, ig.key, "skin_monotonic")) found += 1;
        if (std.mem.eql(u8, ig.key, "initial_bottom_layers")) found += 1;
    }
    try testing.expectEqual(@as(usize, 3), found);
    try testing.expectEqual(@as(usize, 3), ps.ignored.len);
}

test "Cura object settings: a line distance sets the density of the pattern" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const E = struct { key: []const u8, value: []const u8 };
    var base: Settings = .{};
    base.project.line_width = 0.5;
    const grid = [_]E{
        .{ .key = "cura:infill_line_distance", .value = "3" },
        .{ .key = "cura:infill_pattern", .value = "grid" },
        .{ .key = "cura:infill_sparse_density", .value = "20" },
    };
    var s = base;
    try testing.expect(applyPart(&s, try partSettings(arena, &grid, &base)) == null);
    // Two sets 3 mm apart: 2 x 0.5 / 3.
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), s.project.infill_density, 1e-9);
    const plain = [_]E{.{ .key = "cura:infill_sparse_density", .value = "=100" }};
    const ps = try partSettings(arena, &plain, &base);
    try testing.expectEqual(PartRole.normal, ps.role);
    try testing.expectEqual(@as(usize, 1), ps.sets.len);
    try testing.expectEqualStrings("1", ps.sets[0].value);
}
