//! Bambu Lab printers in LAN mode: the file that they print, and the
//! messages that start a print and ask for the status.
//!
//! A shell sends a print in three steps (the network is the shell's work):
//!
//! 1. It uploads the file of `gcode3mf` over FTPS: implicit TLS on port
//!    990, the user "bblp", the access code of the printer (on its screen)
//!    as the password, to the root folder, with a name that ends in
//!    ".gcode.3mf".
//! 2. It connects to the MQTT broker of the printer: TLS on port 8883, the
//!    same user and password, and subscribes to "device/<serial>/report".
//! 3. After the user confirms that the plate is clear (a fresh click; never
//!    a timer or a retry), it publishes `startMessage` to
//!    "device/<serial>/request". `pushAllMessage` asks for the full status,
//!    and each report gives the state, the layer, and the time left.
//!
//! The printer reads the G-code of plate 1 (Metadata/plate_1.gcode) and its
//! MD5 (Metadata/plate_1.gcode.md5) from the 3MF file. The model part of
//! the file is empty: the printer prints the G-code.
//!
//! The file layout and the messages follow the public documents of the
//! LAN mode and the open source tools for it (see REFERENCES.md). No code
//! comes from them.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zipfile = @import("zipfile.zig");

/// The facts of the plate for Metadata/slice_info.config, as Bambu Studio
/// writes them: a printdeck reads them to list the file (its time and
/// grams) and to give each filament the tray of the AMS with the same
/// material and the nearest color. 0 or "": not known.
pub const PlateInfo = struct {
    /// The print time that the slicer predicts, s.
    seconds: f64 = 0,
    grams: f64 = 0,
    meters: f64 = 0,
    /// "PLA".
    material: []const u8 = "",
    /// "#RRGGBB".
    color: []const u8 = "",
    nozzle: f64 = 0,
    /// The filaments of a print with more than one: each with its slot of
    /// the AMS. When it has any, they replace material and color.
    filaments: []const FilamentUse = &.{},
    /// The nozzles of the printer: 2 for a head with a second nozzle (the
    /// X2D). Then the file tells the nozzle of each filament
    /// (filament_maps, group_id), as Bambu Studio writes it.
    nozzles: u32 = 1,
    /// The model code of the printer (printer_model_id), for example "N6"
    /// for the X2D (BambuStudio resources/printers), or "".
    model_id: []const u8 = "",
    /// The print has support.
    support_used: bool = false,
    /// For Metadata/project_settings.config: the printer model as Bambu
    /// Studio names it ("Bambu Lab X2D"), the build plate
    /// ("Textured PEI Plate"), and the nozzle ("hardened_steel",
    /// "Standard"). Empty printer_model: no such file.
    printer_model: []const u8 = "",
    bed_type: []const u8 = "",
    nozzle_type: []const u8 = "hardened_steel",
    nozzle_flow: []const u8 = "Standard",
    /// The extruder types, the default volume types (";" between nozzles),
    /// and the extruder variant lists ("|" between nozzles) of the model
    /// (printers.Bambu).
    extruder_types: []const u8 = "Direct Drive",
    default_volumes: []const u8 = "Standard",
    variants: []const u8 = "",
    /// The project_settings.config of a Bambu Studio file of this model
    /// (printers.bambuProject), or "": then zslice writes its own few keys.
    /// zslice writes its values over it (see projectSettings).
    base_project: []const u8 = "",
    layer_height: f64 = 0.2,
    first_layer_height: f64 = 0.2,
    /// The box of the parts on the bed (min x, min y, max x, max y, mm),
    /// for plate_1.json: the printer looks for foreign objects and checks
    /// the first layer around it. Null: no box.
    bbox: ?[4]f64 = null,
    /// The name of the plate's object, and its area on the bed (mm²).
    object_name: []const u8 = "zslice",
    first_layer_time: f64 = 0,
    /// The <layer_filament_lists> element of slice_info.config (see
    /// layerFilamentLists), or "".
    layer_lists: []const u8 = "",
};

/// The <layer_filament_lists> of Bambu Studio for a G-code: for each set
/// of filaments that a run of layers uses (from 0, space between), the
/// ranges of those layers ("a b", comma between). It reads the ";LAYER:n"
/// marks and the "T<n>" tool changes. "" for a print of one filament.
pub fn layerFilamentLists(a: Allocator, gcode: []const u8) Allocator.Error![]const u8 {
    // The set of tools of each layer, as a bit mask.
    var masks: std.ArrayList(u64) = .empty;
    var tool: u32 = 0;
    var any_change = false;
    var it = std.mem.splitScalar(u8, gcode, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) {
            try masks.append(a, @as(u64, 1) << @intCast(tool));
            continue;
        }
        if (line.len < 2 or line[0] != 'T' or !std.ascii.isDigit(line[1])) continue;
        var e: usize = 1;
        while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
        if (e < line.len and line[e] != ' ' and line[e] != ';' and line[e] != '\r') continue;
        const t = std.fmt.parseInt(u32, line[1..e], 10) catch continue;
        if (t >= 64) continue;
        if (t != tool and masks.items.len > 0) any_change = true;
        tool = t;
        if (masks.items.len > 0) masks.items[masks.items.len - 1] |= @as(u64, 1) << @intCast(t);
    }
    if (!any_change or masks.items.len == 0) return "";
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.writeAll("    <layer_filament_lists>\n") catch return error.OutOfMemory;
    // Each distinct mask, in the order of its first layer.
    var seen: std.ArrayList(u64) = .empty;
    for (masks.items) |m| {
        if (std.mem.indexOfScalar(u64, seen.items, m) != null) continue;
        try seen.append(a, m);
        w.writeAll("      <layer_filament_list filament_list=\"") catch return error.OutOfMemory;
        var first = true;
        for (0..64) |b| if (m & (@as(u64, 1) << @intCast(b)) != 0) {
            w.print("{s}{d}", .{ if (first) "" else " ", b }) catch return error.OutOfMemory;
            first = false;
        };
        w.writeAll("\" layer_ranges=\"") catch return error.OutOfMemory;
        var k: usize = 0;
        var n: usize = 0;
        while (k < masks.items.len) {
            if (masks.items[k] != m) {
                k += 1;
                continue;
            }
            var j = k;
            while (j + 1 < masks.items.len and masks.items[j + 1] == m) j += 1;
            w.print("{s}{d} {d}", .{ if (n > 0) "," else "", k, j }) catch return error.OutOfMemory;
            n += 1;
            k = j + 1;
        }
        w.writeAll("\" />\n") catch return error.OutOfMemory;
    }
    w.writeAll("    </layer_filament_lists>\n") catch return error.OutOfMemory;
    return out.written();
}

/// A JSON list of the parts of `text` between `sep`.
fn jsonList(w: *std.Io.Writer, key: []const u8, text: []const u8, sep: u8, comma: bool) std.Io.Writer.Error!void {
    try w.print("    \"{s}\": [", .{key});
    var it = std.mem.splitScalar(u8, text, sep);
    var first = true;
    while (it.next()) |part| {
        try w.print("{s}\"{s}\"", .{ if (first) "" else ", ", part });
        first = false;
    }
    try w.print("]{s}\n", .{if (comma) "," else ""});
}

/// Metadata/project_settings.config: the settings of Bambu Studio that the
/// printer reads to check the file (the model, the nozzles, the plate, and
/// the filaments). JSON, with each value a string or a list of strings.
fn projectSettings(a: Allocator, info: PlateInfo) Allocator.Error![]u8 {
    if (info.base_project.len > 0) {
        if (overProject(a, info)) |text| return text else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // A base that does not parse: the few keys of zslice.
            else => {},
        }
    }
    var w: std.Io.Writer.Allocating = .init(a);
    const ww = &w.writer;
    const n: u32 = @max(info.nozzles, 1);
    const d = if (info.nozzle > 0) info.nozzle else 0.4;
    const list = struct {
        fn f(out: *std.Io.Writer, key: []const u8, count: u32, text: []const u8, comma: bool) !void {
            try out.print("    \"{s}\": [", .{key});
            for (0..count) |k| try out.print("{s}\"{s}\"", .{ if (k > 0) ", " else "", text });
            try out.print("]{s}\n", .{if (comma) "," else ""});
        }
    }.f;
    (blk: {
        ww.writeAll("{\n") catch |e| break :blk e;
        ww.print("    \"printer_model\": \"{s}\",\n", .{info.printer_model}) catch |e| break :blk e;
        ww.print("    \"printer_settings_id\": \"{s} {d} nozzle\",\n", .{ info.printer_model, d }) catch |e| break :blk e;
        ww.print("    \"printer_variant\": \"{d}\",\n", .{d}) catch |e| break :blk e;
        var dbuf: [32]u8 = undefined;
        const ds = std.fmt.bufPrint(&dbuf, "{d}", .{d}) catch "0.4";
        list(ww, "nozzle_diameter", n, ds, true) catch |e| break :blk e;
        list(ww, "nozzle_volume_type", n, info.nozzle_flow, true) catch |e| break :blk e;
        jsonList(ww, "extruder_type", info.extruder_types, ';', true) catch |e| break :blk e;
        jsonList(ww, "default_nozzle_volume_type", info.default_volumes, ';', true) catch |e| break :blk e;
        if (info.variants.len > 0) jsonList(ww, "extruder_variant_list", info.variants, '|', true) catch |e| break :blk e;
        ww.print("    \"curr_bed_type\": \"{s}\",\n", .{info.bed_type}) catch |e| break :blk e;
        // The filaments by id, from 1 to the last of the print.
        var last: u32 = 1;
        for (info.filaments) |f| last = @max(last, f.id);
        const keys = [_][]const u8{ "filament_type", "filament_colour", "filament_map" };
        for (keys, 0..) |key, ki| {
            ww.print("    \"{s}\": [", .{key}) catch |e| break :blk e;
            for (1..last + 1) |id| {
                var text: []const u8 = switch (ki) {
                    0 => "PLA",
                    1 => "#FFFFFF",
                    else => "1",
                };
                var mb: [4]u8 = undefined;
                for (info.filaments) |f| if (f.id == id) {
                    text = switch (ki) {
                        0 => f.kind,
                        1 => if (f.color.len == 7) f.color else "#FFFFFF",
                        else => std.fmt.bufPrint(&mb, "{d}", .{@as(u32, @min(f.nozzle, 1)) + 1}) catch "1",
                    };
                };
                if (ki == 0 and info.filaments.len == 0 and info.material.len > 0) text = info.material;
                if (ki == 1 and info.filaments.len == 0 and info.color.len == 7) text = info.color;
                ww.print("{s}\"{s}\"", .{ if (id > 1) ", " else "", try jsonText(a, text) }) catch |e| break :blk e;
            }
            ww.print("]{s}\n", .{if (ki + 1 < keys.len) "," else ""}) catch |e| break :blk e;
        }
        ww.writeAll("}\n") catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return w.toOwnedSlice() catch error.OutOfMemory;
}



/// The project_settings.config of Bambu Studio (`info.base_project`) with
/// the values of zslice over it: the build plate, the type and the color
/// of each filament, the layer heights, and the flow of the nozzles. All
/// the other keys stay as Bambu Studio wrote them for this model: the
/// printer reads its hotends and extruders from them.
fn overProject(a: Allocator, info: PlateInfo) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, info.base_project, .{});
    const o = &parsed.value.object;
    const str = struct {
        fn v(al: Allocator, text: []const u8) !std.json.Value {
            return .{ .string = try al.dupe(u8, text) };
        }
    }.v;
    try o.put(a, "curr_bed_type", try str(a, info.bed_type));
    var lh: [32]u8 = undefined;
    try o.put(a, "layer_height", try str(a, std.fmt.bufPrint(&lh, "{d}", .{info.layer_height}) catch "0.2"));
    try o.put(a, "initial_layer_print_height", try str(a, std.fmt.bufPrint(&lh, "{d}", .{info.first_layer_height}) catch "0.2"));
    // The filaments by id, from 1 to the last of the print.
    var last: u32 = 1;
    for (info.filaments) |f| last = @max(last, f.id);
    var types = std.json.Array.init(a);
    var colours = std.json.Array.init(a);
    for (1..last + 1) |id| {
        var kind: []const u8 = if (info.material.len > 0) info.material else "PLA";
        var color: []const u8 = if (info.color.len == 7) info.color else "#FFFFFF";
        for (info.filaments) |f| if (f.id == id) {
            kind = f.kind;
            color = if (f.color.len == 7) f.color else "#FFFFFF";
        };
        try types.append(try str(a, kind));
        try colours.append(try str(a, color));
    }
    try o.put(a, "filament_type", .{ .array = types });
    try o.put(a, "filament_colour", .{ .array = colours });
    // The flow of the nozzles of the user (high flow), for each extruder.
    if (std.mem.eql(u8, info.nozzle_flow, "High Flow")) {
        const n: u32 = @max(info.nozzles, 1);
        var vol = std.json.Array.init(a);
        var stats = std.json.Array.init(a);
        for (0..n) |_| {
            try vol.append(try str(a, "High Flow"));
            try stats.append(try str(a, "High Flow#1"));
        }
        try o.put(a, "nozzle_volume_type", .{ .array = vol });
        try o.put(a, "extruder_nozzle_volume_type", .{ .array = try vol.clone() });
        try o.put(a, "extruder_nozzle_stats", .{ .array = stats });
        try o.put(a, "extruder_nozzle_stats_new", .{ .array = try stats.clone() });
    }
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_4 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// `text` with the quotes and the back slashes of a JSON string escaped.
fn jsonText(a: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '"', '\\' => {
            try out.append(a, '\\');
            try out.append(a, c);
        },
        0...31 => try out.append(a, ' '),
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

/// The key of a build plate in plate_1.json ("textured_plate") for its
/// name ("Textured PEI Plate").
fn bedTypeKey(name: []const u8) []const u8 {
    const keys = [_][2][]const u8{
        .{ "Cool Plate", "cool_plate" },         .{ "Engineering Plate", "eng_plate" },
        .{ "High Temp Plate", "hot_plate" },     .{ "Textured PEI Plate", "textured_plate" },
        .{ "Supertack Plate", "supertack_plate" },
    };
    for (keys) |k| if (std.mem.eql(u8, k[0], name)) return k[1];
    return "textured_plate";
}

/// The id of the generic filament of Bambu Studio for a material
/// (tray_info_idx), or "".
pub fn genericFilament(material: []const u8) []const u8 {
    const ids = [_][2][]const u8{
        .{ "PLA", "GFL99" }, .{ "PETG", "GFG99" }, .{ "ABS", "GFB99" }, .{ "ASA", "GFB98" },
        .{ "TPU", "GFU99" }, .{ "PA", "GFN99" },   .{ "PC", "GFC99" },  .{ "PVA", "GFS99" },
    };
    for (ids) |e| if (std.ascii.eqlIgnoreCase(e[0], material)) return e[1];
    return "";
}

/// A filament of the print, for the slice info of a .gcode.3mf file.
pub const FilamentUse = struct {
    /// The filament (from 1): the slot of the AMS that the print uses.
    id: u32,
    /// The type ("PLA") and the color ("#rrggbb").
    kind: []const u8,
    color: []const u8,
    meters: f64,
    grams: f64,
    /// The nozzle of the filament on a printer with two: 0 main, 1 second.
    nozzle: u32 = 0,
    /// The filament prints the parts, and the support.
    for_object: bool = true,
    for_support: bool = false,
};

/// `text` with the 5 special characters of XML escaped.
fn xmlText(a: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

/// Metadata/slice_info.config: plate 1, its time and grams, and its one
/// filament.
fn sliceInfo(a: Allocator, info: PlateInfo) Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    const ww = &w.writer;
    ww.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<config>
        \\  <header>
        \\    <header_item key="X-BBL-Client-Type" value="slicer"/>
        \\    <header_item key="X-BBL-Client-Version" value="zslice"/>
        \\  </header>
        \\  <plate>
        \\    <metadata key="index" value="1"/>
        \\
    ) catch return error.OutOfMemory;
    ww.print("    <metadata key=\"prediction\" value=\"{d}\"/>\n", .{@as(i64, @intFromFloat(@round(@max(0, info.seconds))))}) catch return error.OutOfMemory;
    ww.print("    <metadata key=\"weight\" value=\"{d:.2}\"/>\n", .{@max(0, info.grams)}) catch return error.OutOfMemory;
    if (info.model_id.len > 0) ww.print("    <metadata key=\"printer_model_id\" value=\"{s}\"/>\n", .{try xmlText(a, info.model_id)}) catch return error.OutOfMemory;
    // The lists of each extruder: types (0 direct drive, 1 Bowden), volume
    // types (0 standard, 1 high flow), diameters ("0.4,0.4").
    const n_noz: u32 = @max(info.nozzles, 1);
    {
        ww.writeAll("    <metadata key=\"extruder_type\" value=\"") catch return error.OutOfMemory;
        var it = std.mem.splitScalar(u8, info.extruder_types, ';');
        var k: u32 = 0;
        while (it.next()) |t| : (k += 1) ww.print("{s}{d}", .{ if (k > 0) " " else "", @intFromBool(std.mem.eql(u8, t, "Bowden")) }) catch return error.OutOfMemory;
        ww.writeAll("\"/>\n    <metadata key=\"nozzle_volume_type\" value=\"") catch return error.OutOfMemory;
        const flow: u32 = @intFromBool(std.mem.eql(u8, info.nozzle_flow, "High Flow"));
        for (0..n_noz) |j| ww.print("{s}{d}", .{ if (j > 0) " " else "", flow }) catch return error.OutOfMemory;
        ww.writeAll("\"/>\n") catch return error.OutOfMemory;
    }
    if (info.nozzle > 0) {
        ww.writeAll("    <metadata key=\"nozzle_diameters\" value=\"") catch return error.OutOfMemory;
        for (0..n_noz) |j| ww.print("{s}{d}", .{ if (j > 0) "," else "", info.nozzle }) catch return error.OutOfMemory;
        ww.writeAll("\"/>\n") catch return error.OutOfMemory;
    }
    // The plate keys of Bambu Studio (bbs_3mf.cpp): no time lapse, all in
    // the bed, and no labels of objects (zslice writes no EXCLUDE_OBJECT).
    ww.writeAll("    <metadata key=\"timelapse_type\" value=\"0\"/>\n    <metadata key=\"outside\" value=\"false\"/>\n") catch return error.OutOfMemory;
    ww.print("    <metadata key=\"support_used\" value=\"{s}\"/>\n    <metadata key=\"label_object_enabled\" value=\"false\"/>\n", .{if (info.support_used) "true" else "false"}) catch return error.OutOfMemory;
    ww.writeAll("    <metadata key=\"pause_count\" value=\"0\"/>\n    <metadata key=\"support_material_on_wipe_tower\" value=\"false\"/>\n") catch return error.OutOfMemory;
    // Each filament has one nozzle (no dynamic map), of one diameter, and
    // no filament switcher (as Bambu Studio 02.09 writes it for the X2D).
    if (info.nozzles >= 2) ww.writeAll("    <metadata key=\"enable_filament_dynamic_map\" value=\"false\"/>\n    <metadata key=\"has_filament_switcher\" value=\"false\"/>\n    <metadata key=\"multi_nozzle_diameter_mode\" value=\"0\"/>\n") catch return error.OutOfMemory;
    // Two nozzles: the extruder of each filament (from 1), for the ids
    // 1 to the last filament of the print; a filament that the print does
    // not use gets extruder 1.
    const two = info.nozzles >= 2 and info.filaments.len > 0;
    if (two) {
        var last: u32 = 0;
        for (info.filaments) |f| last = @max(last, f.id);
        ww.writeAll("    <metadata key=\"filament_maps\" value=\"") catch return error.OutOfMemory;
        for (1..last + 1) |id| {
            var e: u32 = 1;
            for (info.filaments) |f| if (f.id == id) {
                e = @as(u32, @min(f.nozzle, 1)) + 1;
            };
            ww.print("{s}{d}", .{ if (id > 1) " " else "", e }) catch return error.OutOfMemory;
        }
        ww.writeAll("\"/>\n") catch return error.OutOfMemory;
        ww.writeAll("    <metadata key=\"limit_filament_maps\" value=\"") catch return error.OutOfMemory;
        for (1..last + 1) |id| ww.print("{s}0", .{if (id > 1) " " else ""}) catch return error.OutOfMemory;
        ww.writeAll("\"/>\n") catch return error.OutOfMemory;
    }
    for (info.filaments) |f| {
        const color = if (f.color.len == 7 and f.color[0] == '#') f.color else "#FFFFFF";
        ww.print("    <filament id=\"{d}\" type=\"{s}\" color=\"{s}\" used_m=\"{d:.2}\" used_g=\"{d:.2}\"", .{ f.id, try xmlText(a, f.kind), try xmlText(a, color), @max(0, f.meters), @max(0, f.grams) }) catch return error.OutOfMemory;
        const idx = genericFilament(f.kind);
        if (idx.len > 0) ww.print(" tray_info_idx=\"{s}\"", .{idx}) catch return error.OutOfMemory;
        ww.print(" used_for_object=\"{s}\" used_for_support=\"{s}\" directly_used=\"true\"", .{ if (f.for_object) "true" else "false", if (f.for_support) "true" else "false" }) catch return error.OutOfMemory;
        if (two) ww.print(" group_id=\"{d}\"", .{@min(f.nozzle, 1)}) catch return error.OutOfMemory;
        if (info.nozzle > 0) ww.print(" nozzle_diameter=\"{d}\" volume_type=\"Standard\"", .{info.nozzle}) catch return error.OutOfMemory;
        ww.writeAll("/>\n") catch return error.OutOfMemory;
    }
    // The nozzles that the print uses.
    if (two) for (0..2) |g| {
        var used = false;
        for (info.filaments) |f| used = used or @min(f.nozzle, 1) == g;
        if (!used) continue;
        ww.print("    <nozzle id=\"{d}\" extruder_id=\"{d}\" nozzle_diameter=\"{d}\" volume_type=\"Standard\"/>\n", .{ g, g + 1, if (info.nozzle > 0) info.nozzle else 0.4 }) catch return error.OutOfMemory;
    };
    if (info.filaments.len == 0 and info.material.len > 0) {
        const color = if (info.color.len == 7 and info.color[0] == '#') info.color else "#FFFFFF";
        ww.print("    <filament id=\"1\" type=\"{s}\" color=\"{s}\" used_m=\"{d:.2}\" used_g=\"{d:.2}\"/>\n", .{ try xmlText(a, info.material), try xmlText(a, color), @max(0, info.meters), @max(0, info.grams) }) catch return error.OutOfMemory;
    }
    // The filaments of each run of layers, after the nozzles (as Studio).
    ww.writeAll(info.layer_lists) catch return error.OutOfMemory;
    ww.writeAll("  </plate>\n</config>\n") catch return error.OutOfMemory;
    return w.toOwnedSlice() catch error.OutOfMemory;
}

/// A .gcode.3mf file with the G-code as plate 1, in gpa.
pub fn gcode3mf(gpa: Allocator, gcode: []const u8, title: []const u8) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    return gcode3mfPlate(gpa, gcode, title, .{});
}

/// `gcode3mfPlate` with the filaments that the print uses (a print of
/// more than one filament): the screen of the printer shows them, and the
/// AMS mapping of a start message (see `Start`) maps them to its slots.
pub fn gcode3mfWith(gpa: Allocator, gcode: []const u8, title: []const u8, filaments: []const FilamentUse) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    return gcode3mfWithTime(gpa, gcode, title, filaments, 0);
}

/// `gcode3mfWith` and the print time that the slicer predicts (s), which
/// a printdeck lists with the file.
pub fn gcode3mfWithTime(gpa: Allocator, gcode: []const u8, title: []const u8, filaments: []const FilamentUse, seconds: f64) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    return gcode3mfNozzles(gpa, gcode, title, filaments, seconds, 1);
}

/// `gcode3mfWithTime` for a printer with `nozzles` nozzles: with 2, the
/// file tells the nozzle of each filament (FilamentUse.nozzle).
pub fn gcode3mfNozzles(gpa: Allocator, gcode: []const u8, title: []const u8, filaments: []const FilamentUse, seconds: f64, nozzles: u32) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    return gcode3mfInfo(gpa, gcode, title, .{ .filaments = filaments, .seconds = seconds, .nozzles = nozzles });
}

/// The .gcode.3mf of `info` (the grams and meters come from its
/// filaments).
pub fn gcode3mfInfo(gpa: Allocator, gcode: []const u8, title: []const u8, info_in: PlateInfo) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    var info = info_in;
    var lists_arena = std.heap.ArenaAllocator.init(gpa);
    defer lists_arena.deinit();
    if (info.layer_lists.len == 0) info.layer_lists = try layerFilamentLists(lists_arena.allocator(), gcode);
    const filaments = info.filaments;
    for (filaments) |f| {
        info.grams += f.grams;
        info.meters += f.meters;
    }
    return gcode3mfPlate(gpa, gcode, title, info);
}

/// A .gcode.3mf file with the G-code as plate 1 and the facts of the
/// plate (Metadata/slice_info.config), in gpa.
pub fn gcode3mfPlate(gpa: Allocator, gcode: []const u8, title: []const u8, info: PlateInfo) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const md5 = try a.dupe(u8, &gcodeMd5(gcode));
    const types =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/><Default Extension="gcode" ContentType="text/x.gcode"/><Default Extension="png" ContentType="image/png"/></Types>
        \\
    ;
    const rels =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        \\
    ;
    const model = try std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        \\ <metadata name="Application">zslice</metadata>
        \\ <metadata name="Title">{s}</metadata>
        \\ <resources/>
        \\ <build/>
        \\</model>
        \\
    , .{try xmlText(a, title)});
    // The plate of model_settings.config, as Bambu Studio writes it: with
    // the extruder of each filament (filament_maps), the map mode, and
    // the volume map, which a printer with two nozzles reads.
    var maps: std.Io.Writer.Allocating = .init(a);
    {
        var last: u32 = 1;
        for (info.filaments) |f| last = @max(last, f.id);
        for (1..last + 1) |id| {
            var e: u32 = 1;
            for (info.filaments) |f| if (f.id == id and info.nozzles >= 2) {
                e = @as(u32, @min(f.nozzle, 1)) + 1;
            };
            try maps.writer.print("{s}{d}", .{ if (id > 1) " " else "", e });
        }
    }
    var zeros: std.Io.Writer.Allocating = .init(a);
    for (0..std.mem.count(u8, maps.written(), " ") + 1) |k| try zeros.writer.print("{s}0", .{if (k > 0) " " else ""});
    const settings = try std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<config>
        \\  <plate>
        \\    <metadata key="plater_id" value="1"/>
        \\    <metadata key="plater_name" value=""/>
        \\    <metadata key="locked" value="false"/>
        \\    <metadata key="filament_map_mode" value="Manual"/>
        \\    <metadata key="filament_maps" value="{s}"/>
        \\    <metadata key="filament_volume_maps" value="{s}"/>
        \\    <metadata key="gcode_file" value="Metadata/plate_1.gcode"/>
        \\    <metadata key="pattern_bbox_file" value="Metadata/plate_1.json"/>
        \\  </plate>
        \\</config>
        \\
    , .{ maps.written(), zeros.written() });
    // filament_sequence.json: the filament (from 1) of each tool change in
    // order, the first filament too, from the "T<n>" lines of the G-code,
    // and the nozzle of each (as Bambu Studio writes it for a printer with
    // two nozzles).
    var seq: std.Io.Writer.Allocating = .init(a);
    {
        var tools: std.ArrayList(u32) = .empty;
        var it = std.mem.splitScalar(u8, gcode, '\n');
        while (it.next()) |line| {
            if (line.len < 2 or line[0] != 'T' or !std.ascii.isDigit(line[1])) continue;
            var e: usize = 1;
            while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
            if (e < line.len and line[e] != ' ' and line[e] != ';' and line[e] != '\r') continue;
            const t = std.fmt.parseInt(u32, line[1..e], 10) catch continue;
            if (t >= 64) continue; // T65279 and T65535: the unload of the end
            if (tools.items.len > 0 and tools.items[tools.items.len - 1] == t) continue;
            try tools.append(a, t);
        }
        const nozzleOfTool = struct {
            fn f(fs: []const FilamentUse, nozzles: u32, t: u32) u32 {
                if (nozzles < 2) return 0;
                for (fs) |fu| if (fu.id == t + 1) return @min(fu.nozzle, 1);
                return 0;
            }
        }.f;
        try seq.writer.writeAll("{\"plate_1\":{\"nozzle_sequence\":[");
        for (tools.items, 0..) |t, k| try seq.writer.print("{s}{d}", .{ if (k > 0) "," else "", nozzleOfTool(info.filaments, info.nozzles, t) });
        try seq.writer.writeAll("],\"optimal_assignment\":[");
        for (info.filaments, 0..) |f, k| try seq.writer.print("{s}{d}", .{ if (k > 0) "," else "", if (info.nozzles >= 2) @min(f.nozzle, 1) else 0 });
        try seq.writer.writeAll("],\"sequence\":[");
        for (tools.items, 0..) |t, k| try seq.writer.print("{s}{d}", .{ if (k > 0) "," else "", t + 1 });
        try seq.writer.writeAll("]}}");
    }
    // plate_1.json: the plate type, the filaments, and the nozzle.
    var pj: std.Io.Writer.Allocating = .init(a);
    {
        const w = &pj.writer;
        try w.writeByte('{');
        if (info.bbox) |b| {
            try w.print("\"bbox_all\":[{d},{d},{d},{d}],\"bbox_objects\":[{{\"area\":{d},\"bbox\":[{d},{d},{d},{d}],\"id\":1,\"layer_height\":{d},\"name\":\"{s}\"}}],", .{ b[0], b[1], b[2], b[3], (b[2] - b[0]) * (b[3] - b[1]), b[0], b[1], b[2], b[3], info.layer_height, try jsonText(a, info.object_name) });
        }
        try w.print("\"bed_type\":\"{s}\",\"filament_colors\":[", .{bedTypeKey(info.bed_type)});
        for (info.filaments, 0..) |f, n| try w.print("{s}\"{s}\"", .{ if (n > 0) "," else "", try jsonText(a, if (f.color.len == 7) f.color else "#FFFFFF") });
        try w.writeAll("],\"filament_ids\":[");
        for (info.filaments, 0..) |f, n| try w.print("{s}{d}", .{ if (n > 0) "," else "", f.id - 1 });
        const first: u32 = if (info.filaments.len > 0 and info.nozzles >= 2) @min(info.filaments[0].nozzle, 1) else 0;
        try w.print("],\"first_extruder\":{d},\"first_layer_time\":{d},\"is_seq_print\":false,\"nozzle_diameter\":{d},\"version\":2}}", .{ first, info.first_layer_time, if (info.nozzle > 0) info.nozzle else 0.4 });
    }
    const entries = [_]zipfile.Entry{
        .{ .name = "[Content_Types].xml", .data = @constCast(types) },
        .{ .name = "_rels/.rels", .data = @constCast(rels) },
        .{ .name = "3D/3dmodel.model", .data = model },
        .{ .name = "Metadata/model_settings.config", .data = settings },
        .{ .name = "Metadata/plate_1.json", .data = pj.written() },
        .{ .name = "Metadata/filament_sequence.json", .data = seq.written() },
        .{ .name = "Metadata/plate_1.gcode", .data = @constCast(gcode) },
        .{ .name = "Metadata/plate_1.gcode.md5", .data = md5 },
        .{ .name = "Metadata/slice_info.config", .data = try sliceInfo(a, info) },
        .{ .name = "Metadata/project_settings.config", .data = if (info.printer_model.len > 0) try projectSettings(a, info) else &.{} },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // The project settings only with a known printer model.
    try zipfile.write(gpa, &out.writer, if (info.printer_model.len > 0) &entries else entries[0 .. entries.len - 1]);
    return out.toOwnedSlice();
}

pub const Start = struct {
    /// The name of the file on the printer ("part.gcode.3mf").
    file: []const u8,
    /// The name of the print on the screen of the printer.
    title: []const u8,
    /// Level the bed before the print.
    bed_leveling: bool = true,
    /// Use the AMS (the filament changer), slot 0.
    use_ams: bool = false,
    timelapse: bool = false,
    /// The MD5 of plate_1.gcode (32 hex digits; `gcodeMd5`), or "". Some
    /// firmware checks it.
    md5: []const u8 = "",
    /// The url form "ftp://<file>" (P1 and A1, reported), in place of
    /// "file:///sdcard/<file>" (X1).
    ftp_url: bool = false,
};

/// The MD5 of the G-code in upper case hex, as the .md5 entry of the file.
pub fn gcodeMd5(gcode: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(gcode, &digest, .{});
    return std.fmt.bytesToHex(digest, .upper);
}

/// The MQTT message that starts the print of a file on the printer. Send
/// it only after a fresh confirmation of the user that the plate is clear.
pub fn startMessage(gpa: Allocator, s: Start) Allocator.Error![]u8 {
    const Msg = struct {
        print: struct {
            sequence_id: []const u8 = "0",
            command: []const u8 = "project_file",
            param: []const u8 = "Metadata/plate_1.gcode",
            project_id: []const u8 = "0",
            profile_id: []const u8 = "0",
            task_id: []const u8 = "0",
            subtask_id: []const u8 = "0",
            subtask_name: []const u8,
            url: []const u8,
            md5: []const u8 = "",
            timelapse: bool,
            bed_type: []const u8 = "auto",
            bed_levelling: bool,
            flow_cali: bool = false,
            vibration_cali: bool = false,
            layer_inspect: bool = false,
            use_ams: bool,
            ams_mapping: []const i32 = &.{0},
        },
    };
    const url = if (s.ftp_url) try std.fmt.allocPrint(gpa, "ftp://{s}", .{s.file}) else try std.fmt.allocPrint(gpa, "file:///sdcard/{s}", .{s.file});
    defer gpa.free(url);
    return std.json.Stringify.valueAlloc(gpa, Msg{ .print = .{
        .subtask_name = s.title,
        .url = url,
        .md5 = s.md5,
        .timelapse = s.timelapse,
        .bed_levelling = s.bed_leveling,
        .use_ams = s.use_ams,
    } }, .{});
}

/// The MQTT message that asks the printer for its full status.
pub const push_all_message = "{\"pushing\":{\"sequence_id\":\"0\",\"command\":\"pushall\"}}";

/// The camera of a Bambu Lab printer in LAN mode. Both kinds use TLS with
/// the self-signed certificate of the printer, the user "bblp", and the
/// access code.
pub const CameraKind = enum(u8) {
    /// The model is not known: try `rtsps`, then `jpeg`.
    unknown = 0,
    /// RTSP over TLS on port 322, H.264 video, at
    /// rtsps://bblp:<code>@<address>:322/streaming/live/1. The X1 series,
    /// the H2 series, the P2S, and the X2D. The printer must have "LAN
    /// Only Liveview" on.
    rtsps = 1,
    /// JPEG frames over TLS on port 6000 (`jpegAuth`): the P1 and A1
    /// series.
    jpeg = 2,
};

/// The camera kind of a printer of the library (its id, for example
/// "bambu-lab-x2d"), from the open source LAN tools (see REFERENCES.md).
pub fn cameraOf(model_id: []const u8) CameraKind {
    const jpeg = [_][]const u8{ "bambu-lab-a1", "bambu-lab-a1-mini", "bambu-lab-p1p", "bambu-lab-p1s" };
    for (jpeg) |m| if (std.mem.eql(u8, model_id, m)) return .jpeg;
    const rtsps = [_][]const u8{ "bambu-lab-x1", "bambu-lab-x1-carbon", "bambu-lab-x1e", "bambu-lab-x2d", "bambu-lab-p2s", "bambu-lab-h2d", "bambu-lab-h2d-pro", "bambu-lab-h2s", "bambu-lab-h2c" };
    for (rtsps) |m| if (std.mem.eql(u8, model_id, m)) return .rtsps;
    return .unknown;
}

/// The port and the path of the camera.
pub const rtsps_port = 322;
pub const rtsps_path = "/streaming/live/1";
pub const jpeg_port = 6000;

/// The 80 bytes that open the JPEG stream of port 6000: four little endian
/// u32 (0x40, 0x3000, 0, 0), then the user and the access code, each in 32
/// bytes with zeros after it. After them, the printer sends each frame as a
/// 16-byte header (the JPEG size as a little endian u32 first) and the
/// JPEG.
pub fn jpegAuth(code: []const u8) [80]u8 {
    var out = [_]u8{0} ** 80;
    std.mem.writeInt(u32, out[0..4], 0x40, .little);
    std.mem.writeInt(u32, out[4..8], 0x3000, .little);
    @memcpy(out[16..20], "bblp");
    const n = @min(code.len, 32);
    @memcpy(out[48..][0..n], code[0..n]);
    return out;
}

/// Collects the bytes of the JPEG stream of port 6000 and gives back each
/// whole frame: a 16-byte header (the size as a little endian u32 first),
/// then the JPEG. The slice of a frame stays valid until the next call.
pub const JpegReader = struct {
    buf: std.ArrayList(u8) = .empty,
    used: usize = 0,

    pub fn deinit(r: *JpegReader, gpa: Allocator) void {
        r.buf.deinit(gpa);
    }

    fn drop(r: *JpegReader) void {
        if (r.used == 0) return;
        const rest = r.buf.items.len - r.used;
        std.mem.copyForwards(u8, r.buf.items[0..rest], r.buf.items[r.used..]);
        r.buf.items.len = rest;
        r.used = 0;
    }

    pub fn feed(r: *JpegReader, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        r.drop();
        try r.buf.appendSlice(gpa, bytes);
    }

    /// The next whole JPEG, or null when more bytes must come.
    /// error.BadFrame: a size of 0 or over 16 MiB, or no JPEG start.
    pub fn next(r: *JpegReader) error{BadFrame}!?[]const u8 {
        r.drop();
        const b = r.buf.items;
        if (b.len < 16) return null;
        const n = std.mem.readInt(u32, b[0..4], .little);
        if (n < 4 or n > 16 * 1024 * 1024) return error.BadFrame;
        if (b.len < 16 + n) return null;
        const jpeg = b[16 .. 16 + n];
        if (jpeg[0] != 0xFF or jpeg[1] != 0xD8) return error.BadFrame;
        r.used = 16 + n;
        return jpeg;
    }
};

test "bambu: the frames of the JPEG stream" {
    const gpa = std.testing.allocator;
    var r: JpegReader = .{};
    defer r.deinit(gpa);
    const jpeg = [_]u8{ 0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9 };
    var head = [_]u8{0} ** 16;
    std.mem.writeInt(u32, head[0..4], jpeg.len, .little);
    try r.feed(gpa, &head);
    try std.testing.expect((try r.next()) == null);
    try r.feed(gpa, jpeg[0..3]);
    try std.testing.expect((try r.next()) == null);
    try r.feed(gpa, jpeg[3..]);
    try std.testing.expectEqualSlices(u8, &jpeg, (try r.next()).?);
    try std.testing.expect((try r.next()) == null);
    try r.feed(gpa, &([_]u8{0} ** 16));
    try std.testing.expectError(error.BadFrame, r.next());
}

test "bambu: the camera of each model" {
    try std.testing.expectEqual(CameraKind.rtsps, cameraOf("bambu-lab-x2d"));
    try std.testing.expectEqual(CameraKind.jpeg, cameraOf("bambu-lab-p1s"));
    try std.testing.expectEqual(CameraKind.unknown, cameraOf("prusa-mk4"));
    const a = jpegAuth("12345678");
    try std.testing.expectEqual(@as(u32, 0x3000), std.mem.readInt(u32, a[4..8], .little));
    try std.testing.expectEqualStrings("bblp", a[16..20]);
    try std.testing.expectEqualStrings("12345678", a[48..56]);
    try std.testing.expectEqual(@as(u8, 0), a[56]);
}

/// The MQTT topics of a printer.
pub fn reportTopic(gpa: Allocator, serial: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "device/{s}/report", .{serial});
}

pub fn requestTopic(gpa: Allocator, serial: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "device/{s}/request", .{serial});
}

const testing = std.testing;

test "bambu: the file has the G-code and its MD5" {
    const gpa = testing.allocator;
    const gcode = "G28\nG1 X10 Y10 E1\n";
    const bytes = try gcode3mf(gpa, gcode, "Benchy");
    defer gpa.free(bytes);
    const list = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, list);
    var found_gcode = false;
    var found_md5 = false;
    for (list) |e| {
        if (std.mem.eql(u8, e.name, "Metadata/plate_1.gcode")) {
            try testing.expectEqualStrings(gcode, e.data);
            found_gcode = true;
        }
        if (std.mem.eql(u8, e.name, "Metadata/plate_1.gcode.md5")) {
            try testing.expectEqual(@as(usize, 32), e.data.len);
            found_md5 = true;
        }
    }
    try testing.expect(found_gcode and found_md5);
}

test "bambu: the file lists the filaments of the print" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{
        .{ .id = 1, .kind = "PLA", .color = "#FFFFFF", .meters = 3.2, .grams = 9.5 },
        .{ .id = 2, .kind = "PLA", .color = "#D93A3A", .meters = 0.4, .grams = 1.2 },
    };
    const bytes = try gcode3mfWith(gpa, "G28\n", "plaque", &fils);
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    var info: ?[]const u8 = null;
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
        info = e.data;
    };
    try std.testing.expect(std.mem.indexOf(u8, info.?, "<filament id=\"2\" type=\"PLA\" color=\"#D93A3A\" used_m=\"0.40\" used_g=\"1.20\" tray_info_idx=\"GFL99\" used_for_object=\"true\" used_for_support=\"false\" directly_used=\"true\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, info.?, "<metadata key=\"support_used\" value=\"false\"/>") != null);
    // The time of the slice goes with the filaments.
    const timed = try gcode3mfWithTime(gpa, "G28\n", "plaque", &fils, 754.6);
    defer gpa.free(timed);
    const entries2 = try zipfile.readAll(gpa, timed);
    defer zipfile.freeAll(gpa, entries2);
    for (entries2) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"prediction\" value=\"755\"") != null);
    };
}

test "bambu: two nozzles: the extruder of each filament and the nozzles" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{
        .{ .id = 1, .kind = "PLA", .color = "#898989", .meters = 3.2, .grams = 9.5 },
        .{ .id = 3, .kind = "PLA", .color = "#DCDCDC", .meters = 0.4, .grams = 1.2, .nozzle = 1 },
    };
    const bytes = try gcode3mfNozzles(gpa, "G28\n", "plaque", &fils, 60, 2);
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    var info: []const u8 = "";
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
        info = e.data;
    };
    try std.testing.expect(std.mem.indexOf(u8, info, "<metadata key=\"filament_maps\" value=\"1 1 2\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "directly_used=\"true\" group_id=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "<nozzle id=\"0\" extruder_id=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "<nozzle id=\"1\" extruder_id=\"2\"") != null);
    // One nozzle: no map.
    const one = try gcode3mfNozzles(gpa, "G28\n", "plaque", &fils, 60, 1);
    defer gpa.free(one);
    const e1 = try zipfile.readAll(gpa, one);
    defer zipfile.freeAll(gpa, e1);
    for (e1) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
        try std.testing.expect(std.mem.indexOf(u8, e.data, "filament_maps") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "group_id") == null);
    };
}

test "bambu: the start message" {
    const gpa = testing.allocator;
    const m = try startMessage(gpa, .{ .file = "benchy.gcode.3mf", .title = "Benchy" });
    defer gpa.free(m);
    try testing.expect(std.mem.indexOf(u8, m, "\"command\":\"project_file\"") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"url\":\"file:///sdcard/benchy.gcode.3mf\"") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"param\":\"Metadata/plate_1.gcode\"") != null);
    const md5 = gcodeMd5("G28\n");
    const m2 = try startMessage(gpa, .{ .file = "a.gcode.3mf", .title = "A", .md5 = &md5, .ftp_url = true });
    defer gpa.free(m2);
    try testing.expect(std.mem.indexOf(u8, m2, "\"url\":\"ftp://a.gcode.3mf\"") != null);
    try testing.expect(std.mem.indexOf(u8, m2, &md5) != null);
}

test "bambu: the slice info of a plate, for a printdeck" {
    const gpa = testing.allocator;
    const bytes = try gcode3mfPlate(gpa, "G28\n", "A & B <1>", .{ .seconds = 3725.4, .grams = 12.345, .meters = 4.1, .material = "PETG", .color = "#1A2B3C", .nozzle = 0.4 });
    defer gpa.free(bytes);
    const list = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, list);
    var info: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    for (list) |e| {
        if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) info = e.data;
        if (std.mem.eql(u8, e.name, "3D/3dmodel.model")) model = e.data;
    }
    const t = info.?;
    try testing.expect(std.mem.indexOf(u8, t, "<metadata key=\"index\" value=\"1\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, t, "<metadata key=\"prediction\" value=\"3725\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, t, "<metadata key=\"weight\" value=\"12.35\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, t, "type=\"PETG\" color=\"#1A2B3C\" used_m=\"4.10\" used_g=\"12.35\"") != null);
    // The title is escaped in the XML of the model.
    try testing.expect(std.mem.indexOf(u8, model.?, "A &amp; B &lt;1&gt;") != null);
    // A file with no facts still has plate 1, so a deck lists it.
    const plain = try gcode3mf(gpa, "G28\n", "x");
    defer gpa.free(plain);
    const list2 = try zipfile.readAll(gpa, plain);
    defer zipfile.freeAll(gpa, list2);
    var found = false;
    for (list2) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
        found = std.mem.indexOf(u8, e.data, "key=\"index\" value=\"1\"") != null and std.mem.indexOf(u8, e.data, "<filament") == null;
    };
    try testing.expect(found);
}

test "bambu: the model code of the X2D, and the keys of a plate" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{.{ .id = 1, .kind = "PETG", .color = "#000000", .meters = 1, .grams = 3 }};
    const bytes = try gcode3mfInfo(gpa, "G28\n", "p", .{ .filaments = &fils, .model_id = "N6", .nozzle = 0.4, .support_used = true });
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"printer_model_id\" value=\"N6\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"support_used\" value=\"true\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "tray_info_idx=\"GFG99\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "nozzle_diameter=\"0.4\" volume_type=\"Standard\"") != null);
    };
}

test "bambu: project_settings.config names the model, the nozzles, the plate, and the filaments" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{
        .{ .id = 1, .kind = "PLA", .color = "#898989", .meters = 1, .grams = 3 },
        .{ .id = 2, .kind = "PETG", .color = "#161616", .meters = 1, .grams = 3, .nozzle = 1 },
    };
    const bytes = try gcode3mfInfo(gpa, "G28\n", "p", .{ .filaments = &fils, .nozzles = 2, .nozzle = 0.4, .printer_model = "Bambu Lab X2D", .bed_type = "Textured PEI Plate", .extruder_types = "Direct Drive;Bowden", .default_volumes = "Standard;Standard", .variants = "Direct Drive Standard|Bowden Standard" });
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    var found = false;
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"extruder_type\" value=\"0 1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"nozzle_volume_type\" value=\"0 0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"nozzle_diameters\" value=\"0.4,0.4\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"has_filament_switcher\" value=\"false\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "key=\"limit_filament_maps\" value=\"0 0\"") != null);
    };
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/project_settings.config")) {
        found = true;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, e.data, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        try std.testing.expectEqualStrings("Bambu Lab X2D", o.get("printer_model").?.string);
        try std.testing.expectEqualStrings("Bambu Lab X2D 0.4 nozzle", o.get("printer_settings_id").?.string);
        try std.testing.expectEqualStrings("Textured PEI Plate", o.get("curr_bed_type").?.string);
        // Bambu Studio writes no nozzle_type.
        try std.testing.expect(o.get("nozzle_type") == null);
        try std.testing.expectEqualStrings("2", o.get("filament_map").?.array.items[1].string);
        try std.testing.expectEqualStrings("PETG", o.get("filament_type").?.array.items[1].string);
        try std.testing.expectEqualStrings("Bowden", o.get("extruder_type").?.array.items[1].string);
        try std.testing.expectEqual(@as(usize, 2), o.get("nozzle_volume_type").?.array.items.len);
    };
    try std.testing.expect(found);
    // A printer of no known Bambu model: no such file.
    const plain = try gcode3mfInfo(gpa, "G28\n", "p", .{ .filaments = &fils });
    defer gpa.free(plain);
    const e2 = try zipfile.readAll(gpa, plain);
    defer zipfile.freeAll(gpa, e2);
    for (e2) |e| try std.testing.expect(!std.mem.eql(u8, e.name, "Metadata/project_settings.config"));
}

test "bambu: a material or a color with quotes stays one JSON string" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{
        .{ .id = 1, .kind = "PLA\", \"x\": \"y", .color = "#\"],\"ab", .meters = 1, .grams = 3 },
    };
    const bytes = try gcode3mfInfo(gpa, "G28\n", "p", .{ .filaments = &fils, .printer_model = "Bambu Lab X1 Carbon", .bbox = .{ 0, 0, 1, 1 } });
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    var n: usize = 0;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "Metadata/project_settings.config")) {
            const parsed = try std.json.parseFromSlice(std.json.Value, gpa, e.data, .{});
            defer parsed.deinit();
            const o = parsed.value.object;
            try std.testing.expectEqualStrings(fils[0].kind, o.get("filament_type").?.array.items[0].string);
            try std.testing.expectEqualStrings(fils[0].color, o.get("filament_colour").?.array.items[0].string);
            n += 1;
        }
        if (std.mem.eql(u8, e.name, "Metadata/plate_1.json")) {
            const parsed = try std.json.parseFromSlice(std.json.Value, gpa, e.data, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings(fils[0].color, parsed.value.object.get("filament_colors").?.array.items[0].string);
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "bambu: the project settings of the X2D are those of Bambu Studio, with the values of zslice" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{
        .{ .id = 1, .kind = "PETG", .color = "#112233", .meters = 1, .grams = 3 },
        .{ .id = 2, .kind = "PLA", .color = "#445566", .meters = 1, .grams = 3, .nozzle = 1 },
        .{ .id = 3, .kind = "ABS", .color = "#778899", .meters = 1, .grams = 3 },
    };
    const base = @import("printers.zig").bambuProject("bambu-lab-x2d").?;
    const bytes = try gcode3mfInfo(gpa, "G28\n", "p", .{ .filaments = &fils, .nozzles = 2, .nozzle = 0.4, .printer_model = "Bambu Lab X2D", .bed_type = "Cool Plate", .base_project = base, .layer_height = 0.16 });
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/project_settings.config")) {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, e.data, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        // All the keys of Bambu Studio, the hotends too.
        try std.testing.expect(o.count() >= 637);
        try std.testing.expectEqualStrings("Standard#1", o.get("extruder_nozzle_stats").?.array.items[1].string);
        try std.testing.expectEqualStrings("1", o.get("physical_extruder_map").?.array.items[0].string);
        // The values of zslice.
        try std.testing.expectEqualStrings("Cool Plate", o.get("curr_bed_type").?.string);
        try std.testing.expectEqualStrings("0.16", o.get("layer_height").?.string);
        try std.testing.expectEqual(@as(usize, 3), o.get("filament_type").?.array.items.len);
        try std.testing.expectEqualStrings("#445566", o.get("filament_colour").?.array.items[1].string);
    };
}

test "bambu: filament_sequence.json lists the tool changes and their nozzles" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{
        .{ .id = 1, .kind = "PLA", .color = "#00AE42", .meters = 1, .grams = 3 },
        .{ .id = 2, .kind = "PLA", .color = "#FFFF00", .meters = 1, .grams = 1, .nozzle = 1 },
    };
    const g = "G28\nT0 H-1\nT0 H-1\nG1 X1\nT1 H-1\nT0 H-1\nT65279\n";
    const bytes = try gcode3mfInfo(gpa, g, "p", .{ .filaments = &fils, .nozzles = 2 });
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    var found = false;
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/filament_sequence.json")) {
        found = true;
        try std.testing.expectEqualStrings("{\"plate_1\":{\"nozzle_sequence\":[0,1,0],\"optimal_assignment\":[0,1],\"sequence\":[1,2,1]}}", e.data);
    };
    try std.testing.expect(found);
}

test "bambu: plate_1.json has the box of the parts, as Bambu Studio writes it" {
    const gpa = std.testing.allocator;
    const fils = [_]FilamentUse{.{ .id = 1, .kind = "PLA", .color = "#00AE42", .meters = 1, .grams = 3 }};
    const bytes = try gcode3mfInfo(gpa, "G28\n", "p", .{ .filaments = &fils, .bbox = .{ 94.4, 69.4, 153.6, 163.4 }, .object_name = "Pod \"body\"", .bed_type = "Textured PEI Plate" });
    defer gpa.free(bytes);
    const entries = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, entries);
    var found = false;
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/plate_1.json")) {
        found = true;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, e.data, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        try std.testing.expectEqual(@as(usize, 4), o.get("bbox_all").?.array.items.len);
        try std.testing.expectEqualStrings("Pod \"body\"", o.get("bbox_objects").?.array.items[0].object.get("name").?.string);
        try std.testing.expectEqualStrings("textured_plate", o.get("bed_type").?.string);
    };
    try std.testing.expect(found);
}

test "bambu: layer_filament_lists from the layers and the tool changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g = "T0 H-1\n;LAYER:0\nG1\n;LAYER:1\nT1 H-1\nG1\nT0 H-1\n;LAYER:2\n;LAYER:3\nT1 H-1\nT0 H-1\n";
    const text = try layerFilamentLists(arena.allocator(), g);
    try std.testing.expect(std.mem.indexOf(u8, text, "filament_list=\"0\" layer_ranges=\"0 0,2 2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "filament_list=\"0 1\" layer_ranges=\"1 1,3 3\"") != null);
    try std.testing.expectEqualStrings("", try layerFilamentLists(arena.allocator(), ";LAYER:0\n;LAYER:1\n"));
}
