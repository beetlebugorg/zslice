//! A comparison of the zslice settings with the settings of a Cura stack.
//!
//! The user prints with Cura and with zslice, and wants to see each
//! setting of the two side by side. The comparison reads a Cura stack (a
//! `cura.json` and the files that it names, see import_cura.zig) with the
//! importer, so the mapping of the Cura keys to the zslice settings is the
//! same as in an import. The steps:
//!
//! 1. `import_cura.resolveStack` gives the Cura values of each layer. The
//!    first quality profile and the first material of cura.json are the
//!    active ones.
//! 2. `import_cura.writeStack` converts them to zslice profiles. The speeds
//!    become ratios of the `machine.max_speed` of zslice now, so a speed
//!    ratio of Cura gives the same mm/s as Cura when the user takes it.
//! 3. The profiles go on a copy of the zslice settings. Each key that a
//!    profile sets is one row: the zslice value now, and the value with
//!    the profiles of Cura.
//! 4. A Cura key of the map whose value is a formula (it starts with "=")
//!    is not imported. If no other key sets its zslice setting, it is a
//!    row with the formula, and the user can only read it.
//!
//! A shell that takes all values sets `machine.max_speed` first and
//! compares again, so the speed ratios relate to the new max speed.
//!
//! Some rows are for the user to read, and "Use all" leaves them out: the
//! names of the printer and of the filament, and the start and end G-code
//! (a printer with Klipper often has its own macros in them).
//!
//! The core does no file I/O, so the stack comes through a
//! `import_cura.Source` callback.
//!
//! References (see REFERENCES.md): the Cura profile formats and the Cura
//! setting names.

const std = @import("std");
const Allocator = std.mem.Allocator;
const import_cura = @import("import_cura.zig");
const profile = @import("profile.zig");
const toml = @import("toml.zig");
const Settings = @import("settings.zig").Settings;
const writeSettingOf = @import("app.zig").App.writeSettingOf;

pub const Source = import_cura.Source;
pub const Diagnostic = import_cura.Diagnostic;
pub const Error = import_cura.Error;

pub const Row = struct {
    /// The dotted zslice name, for example "machine.max_speed".
    name: []const u8,
    /// The value of zslice now, as zs_app_setting_get gives it.
    zslice: []const u8,
    /// The value of Cura as a zslice value, ready to set. For a formula,
    /// the formula of Cura.
    cura: []const u8,
    /// The Cura keys that give the value, with ", " between them.
    cura_keys: []const u8 = "",
    /// The Cura file of the value.
    from: []const u8 = "",
    /// A note for the user, for example the speed of Cura in mm/s.
    note: []const u8 = "",
    differs: bool,
    /// The Cura value is a formula: zslice cannot take it.
    formula: bool = false,
    /// "Use all" takes this value.
    in_use_all: bool,
};

/// The rows that "Use all" leaves out.
const keep_out = [_][]const u8{ "machine.name", "filament.name", "machine.start_gcode", "machine.end_gcode" };

/// Compares `current` with the stack of `src`. The rows are in the order
/// of the profiles: machine, filament, then project.
pub fn compare(arena: Allocator, current: Settings, src: Source, diag: *Diagnostic) Error![]Row {
    var stack = try import_cura.resolveStack(arena, src, diag);
    if (stack.profiles.len == 0) {
        diag.* = .{ .file = "cura.json", .message = "no quality profile" };
        return error.BadFile;
    }
    stack.profiles = stack.profiles[0..1];
    if (stack.materials.len > 1) stack.materials = stack.materials[0..1];
    const outs = try import_cura.writeStack(arena, &stack, .{ .speed_base = current.machine.max_speed });

    // The settings with the profiles of Cura, and the keys that they set.
    var cura = current;
    var names: std.ArrayList([]const u8) = .empty;
    var froms: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "machine", "filament", "project" }) |group| for (outs) |o| {
        if (!std.mem.eql(u8, o.group, group)) continue;
        const g = std.meta.stringToEnum(profile.Group, o.group).?;
        var pd: profile.Diagnostic = .{};
        profile.apply(arena, &cura, g, o.name, o.text, null, &pd) catch {
            diag.* = .{ .file = o.name, .message = "the imported profile does not load" };
            return error.BadFile;
        };
        var td: toml.Diagnostic = .{};
        const entries = toml.parse(arena, o.text, &td) catch return error.BadFile;
        for (entries) |e| {
            if (e.table.len == 0 and g == .project and std.mem.eql(u8, e.key, "name")) continue;
            const name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ if (e.table.len == 0) o.group else e.table, e.key });
            const at = for (names.items, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) break i;
            } else null;
            if (at) |i| {
                froms.items[i] = o.name;
            } else {
                try names.append(arena, name);
                try froms.append(arena, o.name);
            }
        }
    };

    const maps = try import_cura.mappings(arena, &stack, 0);
    var rows: std.ArrayList(Row) = .empty;
    for (names.items, froms.items) |name, out_name| {
        const zs_text = try settingText(arena, current, name);
        const cura_text = try settingText(arena, cura, name);
        var row: Row = .{
            .name = name,
            .zslice = zs_text,
            .cura = cura_text,
            .differs = !sameValue(zs_text, cura_text),
            .in_use_all = false,
        };
        // The Cura keys of the map. The last one with a value that is not
        // a formula wins, as in the import.
        var keys: std.ArrayList(u8) = .empty;
        var winner: ?import_cura.Mapping = null;
        for (maps) |m| {
            if (!std.mem.eql(u8, m.name, name) or m.formula) continue;
            if (keys.items.len > 0) try keys.appendSlice(arena, ", ");
            try keys.appendSlice(arena, m.cura);
            winner = m;
        }
        row.cura_keys = keys.items;
        if (winner) |w| {
            row.from = w.value.from;
            if (w.speed) row.note = try std.fmt.allocPrint(arena, "{s} mm/s in Cura", .{w.value.text});
        } else if (std.mem.eql(u8, name, "machine.max_speed")) {
            row.note = "The highest Cura print speed";
            row.from = out_name;
        } else if (std.mem.startsWith(u8, name, "filament.") and stack.materials.len > 0) {
            row.from = stack.materials[0].file;
        } else {
            row.from = stack.machine_def;
        }
        row.in_use_all = row.differs and !isKeptOut(name);
        try rows.append(arena, row);
    }

    // The formulas of Cura for settings that no other key sets.
    for (maps) |m| {
        if (!m.formula) continue;
        const known = for (rows.items) |r| {
            if (std.mem.eql(u8, r.name, m.name)) break true;
        } else false;
        if (known) continue;
        try rows.append(arena, .{
            .name = m.name,
            .zslice = try settingText(arena, current, m.name),
            .cura = m.value.text,
            .cura_keys = m.cura,
            .from = m.value.from,
            .note = "a formula in Cura: zslice cannot take it",
            .differs = false,
            .formula = true,
            .in_use_all = false,
        });
    }
    return rows.items;
}

fn isKeptOut(name: []const u8) bool {
    for (keep_out) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

fn settingText(arena: Allocator, s: Settings, name: []const u8) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeSettingOf(s, name, &aw.writer) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => return "",
    };
    return aw.written();
}

/// True if two values are the same. Two numbers are the same if they
/// differ by less than one part in a million.
fn sameValue(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const x = std.fmt.parseFloat(f64, a) catch return false;
    const y = std.fmt.parseFloat(f64, b) catch return false;
    return @abs(x - y) <= 1e-6 * @max(1.0, @max(@abs(x), @abs(y)));
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// The files of the test stack in src/testdata/cura_compare.
const TestSource = struct {
    const files = [_][2][]const u8{
        .{ "cura.json", @embedFile("testdata/cura_compare/cura.json") },
        .{ "definitions/acme_box.def.json", @embedFile("testdata/cura_compare/acme_box.def.json") },
        .{ "definitions/acme_box_extruder.def.json", @embedFile("testdata/cura_compare/acme_box_extruder.def.json") },
        .{ "machine_settings.inst.cfg", @embedFile("testdata/cura_compare/machine_settings.inst.cfg") },
        .{ "draft.inst.cfg", @embedFile("testdata/cura_compare/draft.inst.cfg") },
        .{ "fast.inst.cfg", @embedFile("testdata/cura_compare/fast.inst.cfg") },
        .{ "fast_e0.inst.cfg", @embedFile("testdata/cura_compare/fast_e0.inst.cfg") },
        .{ "user.inst.cfg", @embedFile("testdata/cura_compare/user.inst.cfg") },
        .{ "user_e0.inst.cfg", @embedFile("testdata/cura_compare/user_e0.inst.cfg") },
        .{ "gray.xml.fdm_material", @embedFile("testdata/cura_compare/gray.xml.fdm_material") },
    };
    fn read(ctx: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const u8 {
        _ = ctx;
        _ = arena;
        for (files) |f| if (std.mem.eql(u8, f[0], path)) return f[1];
        return null;
    }
};

fn findRow(rows: []const Row, name: []const u8) ?Row {
    for (rows) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

test "compare the zslice settings with a Cura stack" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: Settings = .{};
    s.machine.max_speed = 80;
    s.machine.outer_wall_accel = 0;
    s.filament.xy_offset = 0;
    s.project.layer_height = 0.3;
    var diag: Diagnostic = .{};
    const rows = compare(arena, s, .{ .read = TestSource.read }, &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ diag.file, diag.message });
        return e;
    };

    // The highest print speed of the profile (speed_print 55).
    const ms = findRow(rows, "machine.max_speed").?;
    try testing.expectEqualStrings("80", ms.zslice);
    try testing.expectEqualStrings("55", ms.cura);
    try testing.expect(ms.differs and ms.in_use_all);

    // The user layer wins over the quality changes.
    const accel = findRow(rows, "machine.outer_wall_accel").?;
    try testing.expectEqualStrings("500", accel.cura);
    try testing.expectEqualStrings("user.inst.cfg", accel.from);

    // The material file gives the XY offset.
    const xy = findRow(rows, "filament.xy_offset").?;
    try testing.expectEqualStrings("0.144", xy.cura);
    try testing.expectEqualStrings("gray.xml.fdm_material", xy.from);

    // The quality changes of the extruder win over the material.
    try testing.expectEqualStrings("215", findRow(rows, "filament.nozzle_temp").?.cura);

    // A speed is a ratio of the max speed of zslice now: 25 mm/s of 80.
    const wall = findRow(rows, "project.outer_wall_speed").?;
    try testing.expectEqualStrings("0.3125", wall.cura);
    try testing.expectEqualStrings("25 mm/s in Cura", wall.note);
    try testing.expectEqualStrings("speed_wall_0", wall.cura_keys);

    // The same value is no difference.
    const lh = findRow(rows, "project.layer_height").?;
    try testing.expect(!lh.differs and !lh.in_use_all);

    // The names and the G-code are rows, but not in "Use all".
    const start = findRow(rows, "machine.start_gcode").?;
    try testing.expect(start.differs and !start.in_use_all);
    try testing.expect(!findRow(rows, "machine.name").?.in_use_all);

    // A formula is a row that zslice cannot take.
    const walls = findRow(rows, "project.wall_count").?;
    try testing.expect(walls.formula and !walls.in_use_all);
    try testing.expectEqualStrings("=3 if layer_height < 0.2 else 2", walls.cura);

    // "Use all" as a shell does it: the max speed first, then a new
    // comparison, because the speed ratios relate to the max speed. Each
    // value loads in zslice, and after it no row of "Use all" is left.
    var after = s;
    try after.set(ms.name, ms.cura);
    const second = try compare(arena, after, .{ .read = TestSource.read }, &diag);
    try testing.expectEqualStrings("0.45454545454545453", findRow(second, "project.outer_wall_speed").?.cura);
    for (second) |r| if (r.in_use_all) try after.set(r.name, r.cura);
    const again = try compare(arena, after, .{ .read = TestSource.read }, &diag);
    for (again) |r| if (r.in_use_all) {
        std.debug.print("still differs: {s}: {s} / {s}\n", .{ r.name, r.zslice, r.cura });
        return error.TestUnexpectedResult;
    };
}
