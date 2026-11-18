//! printdeck.yml projects: the parts of a repository, and the plates that
//! print them (printdeck docs/specs/github-builds.md).
//!
//! - `parse` reads a printdeck.yml (yaml.zig): the parts, each with its
//!   files, count, printer, profile ("<folder>/<profile>" of profiles/),
//!   material (a material of that folder), and Cura settings. A part with
//!   variants becomes one part for each variant.
//! - `plan` puts the chosen parts on plates: the parts with the same
//!   printer, profile, material, and plate settings share a plate; a part
//!   with `alone: true` gets its own plate.
//! - `loadPlate` puts a plate on the plate of an App: the Cura profile
//!   stack of the folder (import_cura), the settings of the parts, and
//!   `count` copies of each file, arranged on the bed.
//!
//! The files come through a `Source` (the folder of the repository, or the
//! files of a GitHub repository in the web app).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml.zig");
const import_cura = @import("import_cura.zig");
const settings_mod = @import("settings.zig");

pub const Pair = import_cura.Pair;

pub const Part = struct {
    /// The name, with the variant: "Slate frame (fine)".
    name: []const u8,
    /// The name of the part in printdeck.yml, with no variant.
    base_name: []const u8,
    /// The name of the variant, or "".
    variant: []const u8 = "",
    group: []const u8 = "",
    description: []const u8 = "",
    /// The model files, relative to the repository.
    files: []const []const u8 = &.{},
    /// The copies of each file on the plate.
    count: u32 = 1,
    /// The name of the printer (a deck), for example "taz".
    printer: []const u8 = "",
    /// "<folder>/<profile>" of profiles/, or "".
    profile: []const u8 = "",
    /// A material of the profile folder ("roll-4"), or "".
    material: []const u8 = "",
    /// The Cura settings of the part (the part, then the variant).
    settings: []const Pair = &.{},
    /// The part prints on a plate of its own.
    alone: bool = false,
    /// A file that a person sliced (a resin file), or "".
    prebuilt: []const u8 = "",

    /// The folder of the profile ("taz-workhorse-se"), or "".
    pub fn folder(p: *const Part) []const u8 {
        const slash = std.mem.indexOfScalar(u8, p.profile, '/') orelse return "";
        return p.profile[0..slash];
    }

    /// The profile in its folder ("pla-0.20-standard"), or "".
    pub fn profileName(p: *const Part) []const u8 {
        const slash = std.mem.indexOfScalar(u8, p.profile, '/') orelse return "";
        return p.profile[slash + 1 ..];
    }
};

pub const Project = struct {
    /// The slug of the project ("project:"), or "".
    name: []const u8 = "",
    parts: []const Part = &.{},
};

pub const Diagnostic = struct {
    /// The line in printdeck.yml (1 is the first), or 0.
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{ BadProject, OutOfMemory };

fn fail(diag: *Diagnostic, line: usize, message: []const u8) Error {
    diag.* = .{ .line = line, .message = message };
    return error.BadProject;
}

/// Reads a printdeck.yml. The result is allocated in `arena`.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!Project {
    var yd: yaml.Diagnostic = .{};
    const root = yaml.parse(arena, text, &yd) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadYaml => return fail(diag, yd.line, yd.message),
    };
    if (root.* != .map) return fail(diag, 0, "printdeck.yml is not a map of keys");
    var out: Project = .{};
    if (root.get("project")) |v| out.name = v.str() orelse "";
    const parts_v = root.get("parts") orelse return fail(diag, 0, "printdeck.yml has no parts");
    if (parts_v.* != .list) return fail(diag, 0, "parts is not a list");
    var parts: std.ArrayList(Part) = .empty;
    for (parts_v.list, 0..) |pv, i| {
        if (pv.* != .map) return fail(diag, 0, try std.fmt.allocPrint(arena, "part {d} is not a map", .{i + 1}));
        const base = try readPart(arena, pv, null, diag, i);
        const variants = pv.get("variants");
        if (variants == null or variants.?.* == .null) {
            try parts.append(arena, base);
            continue;
        }
        if (variants.?.* != .list) return fail(diag, 0, try std.fmt.allocPrint(arena, "the variants of {s} are not a list", .{base.name}));
        for (variants.?.list) |vv| {
            if (vv.* != .map) return fail(diag, 0, try std.fmt.allocPrint(arena, "a variant of {s} is not a map", .{base.name}));
            try parts.append(arena, try readPart(arena, vv, &base, diag, i));
        }
    }
    out.parts = parts.items;
    return out;
}

/// A part, or a variant of `base`.
fn readPart(arena: Allocator, v: *const yaml.Value, base: ?*const Part, diag: *Diagnostic, index: usize) Error!Part {
    var p: Part = if (base) |b| b.* else .{ .name = "", .base_name = "" };
    const text = struct {
        fn f(val: *const yaml.Value, key: []const u8) ?[]const u8 {
            const x = val.get(key) orelse return null;
            return x.str();
        }
    }.f;
    if (base) |b| {
        const vname = text(v, "name") orelse return fail(diag, 0, try std.fmt.allocPrint(arena, "a variant of {s} has no name", .{b.base_name}));
        p.variant = vname;
        p.name = try std.fmt.allocPrint(arena, "{s} ({s})", .{ b.base_name, vname });
    } else {
        p.base_name = text(v, "name") orelse try std.fmt.allocPrint(arena, "Part {d}", .{index + 1});
        p.name = p.base_name;
        if (text(v, "group")) |g| p.group = g;
        if (text(v, "description")) |d| p.description = std.mem.trim(u8, d, "\n ");
    }
    if (v.get("files")) |f| {
        const items = try f.items(arena);
        const files = try arena.alloc([]const u8, items.len);
        for (items, files) |it, *out| out.* = it.str() orelse return fail(diag, 0, try std.fmt.allocPrint(arena, "a file of {s} is not a text", .{p.name}));
        p.files = files;
    }
    if (text(v, "count")) |c| p.count = std.fmt.parseInt(u32, c, 10) catch return fail(diag, 0, try std.fmt.allocPrint(arena, "the count of {s} is not a number", .{p.name}));
    if (text(v, "printer")) |x| p.printer = x;
    if (text(v, "profile")) |x| p.profile = x;
    if (text(v, "material")) |x| p.material = x;
    if (text(v, "prebuilt")) |x| p.prebuilt = x;
    if (text(v, "alone")) |x| p.alone = std.ascii.eqlIgnoreCase(x, "true") or std.ascii.eqlIgnoreCase(x, "yes");
    if (v.get("settings")) |s| {
        if (s.* == .map) {
            // The settings of a variant add to the settings of the part.
            var list: std.ArrayList(Pair) = .empty;
            try list.appendSlice(arena, p.settings);
            for (s.map) |e| {
                const value = e.value.str() orelse return fail(diag, 0, try std.fmt.allocPrint(arena, "the setting {s} of {s} is not a value", .{ e.key, p.name }));
                for (list.items) |*old| {
                    if (std.mem.eql(u8, old.key, e.key)) {
                        old.value = value;
                        break;
                    }
                } else try list.append(arena, .{ .key = e.key, .value = value });
            }
            p.settings = list.items;
        } else if (s.* != .null) return fail(diag, 0, try std.fmt.allocPrint(arena, "the settings of {s} are not a map", .{p.name}));
    }
    return p;
}

/// A part on a plate, with its copies.
pub const Item = struct { part: usize, count: u32 };

pub const Plate = struct {
    printer: []const u8,
    profile: []const u8,
    material: []const u8,
    items: []const Item,
};

/// A choice of a part for the plan: on or off, and its count for this
/// plan (null: the count of printdeck.yml).
pub const Choice = struct { on: bool = true, count: ?u32 = null };

/// True if the Cura setting can differ from part to part on one plate
/// (zslice maps it to a layer setting of the part).
fn perPart(arena: Allocator, pair: Pair) Allocator.Error!bool {
    const meta = [_]Pair{.{ .key = try std.fmt.allocPrint(arena, "cura:{s}", .{pair.key}), .value = pair.value }};
    const s: settings_mod.Settings = .{};
    const ps = try import_cura.partSettings(arena, &meta, &s);
    return ps.ignored.len == 0 and ps.sets.len > 0;
}

/// The settings of a part that are the same for the whole plate, sorted
/// by key, as one text ("key=value\n").
pub fn plateKey(arena: Allocator, part: *const Part) Allocator.Error![]const u8 {
    var keys: std.ArrayList(Pair) = .empty;
    for (part.settings) |s| if (!try perPart(arena, s)) try keys.append(arena, s);
    std.mem.sort(Pair, keys.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (keys.items) |k| try out.print(arena, "{s}={s}\n", .{ k.key, k.value });
    return out.items;
}

/// The suggested plates of the chosen parts (`choices`: one for each
/// part, or empty for all parts). The parts with the same printer,
/// profile, material, and plate settings share a plate; a part with
/// `alone` has its own. The order is the order of printdeck.yml. A part
/// with a count of 0 is left out.
pub fn plan(arena: Allocator, project: *const Project, choices: []const Choice) Allocator.Error![]const Plate {
    const Group = struct {
        printer: []const u8,
        profile: []const u8,
        material: []const u8,
        key: []const u8,
        alone: bool,
        items: std.ArrayList(Item) = .empty,
    };
    var groups: std.ArrayList(Group) = .empty;
    for (project.parts, 0..) |*p, i| {
        const c: Choice = if (i < choices.len) choices[i] else .{};
        if (!c.on) continue;
        const count = c.count orelse p.count;
        if (count == 0) continue;
        const key = try plateKey(arena, p);
        const g = if (p.alone) null else for (groups.items) |*g| {
            if (!g.alone and std.mem.eql(u8, g.printer, p.printer) and std.mem.eql(u8, g.profile, p.profile) and
                std.mem.eql(u8, g.material, p.material) and std.mem.eql(u8, g.key, key)) break g;
        } else null;
        const group = g orelse blk: {
            try groups.append(arena, .{ .printer = p.printer, .profile = p.profile, .material = p.material, .key = key, .alone = p.alone });
            break :blk &groups.items[groups.items.len - 1];
        };
        try group.items.append(arena, .{ .part = i, .count = count });
    }
    const out = try arena.alloc(Plate, groups.items.len);
    for (groups.items, out) |*g, *o| o.* = .{ .printer = g.printer, .profile = g.profile, .material = g.material, .items = g.items.items };
    return out;
}

/// The files of a repository that a plate needs: the models, and the
/// files of the profile folders. The apps read them (the folder on the
/// computer, or GitHub) and add them here.
pub const Files = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(gpa: Allocator) Files {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(f: *Files) void {
        f.arena.deinit();
    }

    /// Adds (or replaces) the file at `path`, relative to the repository.
    pub fn add(f: *Files, path: []const u8, bytes: []const u8) Allocator.Error!void {
        const a = f.arena.allocator();
        try f.map.put(a, try a.dupe(u8, normal(path)), try a.dupe(u8, bytes));
    }

    pub fn get(f: *const Files, path: []const u8) ?[]const u8 {
        return f.map.get(normal(path));
    }

    fn normal(path: []const u8) []const u8 {
        var p = path;
        while (std.mem.startsWith(u8, p, "./")) p = p[2..];
        return std.mem.trimStart(u8, p, "/");
    }

    /// A Source for import_cura: the files under `folder`.
    const Sub = struct {
        files: *const Files,
        folder: []const u8,
        fn read(ctx: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const u8 {
            const self: *const Sub = @ptrCast(@alignCast(ctx.?));
            const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ self.folder, path }) catch return null;
            return self.files.get(full);
        }
    };
};

/// A profile of a Cura stack, as a zslice profile text.
pub const Profile = import_cura.Output;

/// The machine, filament, and project profiles of a plate: the Cura
/// stack of profiles/<folder>/ (cura.json), its material, and its quality
/// profile. The apps load them as profiles, then call `addParts`. The
/// texts are in `arena`. On an error, `diag.message` says why.
pub fn plateProfiles(arena: Allocator, files: *const Files, plate: Plate, diag: *Diagnostic) Error![3]Profile {
    const slash = std.mem.indexOfScalar(u8, plate.profile, '/') orelse
        return fail(diag, 0, if (plate.profile.len == 0) "the parts have no profile (a resin part with a prebuilt file: zslice slices FDM parts only)" else "the profile is not <folder>/<profile>");
    const folder = try std.fmt.allocPrint(arena, "profiles/{s}", .{plate.profile[0..slash]});
    const name = plate.profile[slash + 1 ..];
    if (files.get(try std.fmt.allocPrint(arena, "{s}/cura.json", .{folder})) == null)
        return fail(diag, 0, try std.fmt.allocPrint(arena, "{s} has no Cura stack (cura.json). zslice slices FDM parts with a Cura stack; resin parts are not in zslice yet", .{folder}));
    var sub: Files.Sub = .{ .files = files, .folder = folder };
    var idiag: import_cura.Diagnostic = .{};
    const outs = import_cura.importStack(arena, .{ .ctx = &sub, .read = Files.Sub.read }, &idiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diag, 0, try std.fmt.allocPrint(arena, "the Cura stack of {s}: {s}{s}{s}", .{ folder, idiag.file, if (idiag.file.len > 0) ": " else "", if (idiag.message.len > 0) idiag.message else @errorName(e) })),
    };
    var out: [3]?Profile = .{ null, null, null };
    for (outs) |o| {
        if (std.mem.eql(u8, o.group, "machine")) out[0] = o;
        if (std.mem.eql(u8, o.group, "filament") and (std.mem.eql(u8, o.name, plate.material) or (plate.material.len == 0 and out[1] == null))) out[1] = o;
        if (std.mem.eql(u8, o.group, "project") and std.mem.eql(u8, o.name, name)) out[2] = o;
    }
    if (out[0] == null) return fail(diag, 0, try std.fmt.allocPrint(arena, "{s} has no machine", .{folder}));
    if (out[1] == null) return fail(diag, 0, try std.fmt.allocPrint(arena, "{s} has no material {s}", .{ folder, plate.material }));
    if (out[2] == null) return fail(diag, 0, try std.fmt.allocPrint(arena, "{s} has no profile {s}", .{ folder, name }));
    return .{ out[0].?, out[1].?, out[2].? };
}

/// The settings of a plate that are the same for its parts (support,
/// adhesion), as zslice settings from the settings of `app` now. Set them
/// as changes of the print after the profiles of the plate.
pub fn plateSettings(arena: Allocator, project: *const Project, plate: Plate, base: *const settings_mod.Settings, diag: *Diagnostic) Error![]const settings_mod.Change {
    if (plate.items.len == 0) return &.{};
    const part = &project.parts[plate.items[0].part];
    var pairs: std.ArrayList(Pair) = .empty;
    for (part.settings) |s| if (!try perPart(arena, s)) try pairs.append(arena, s);
    const ps = try import_cura.plateSettings(arena, pairs.items, base);
    try checkIgnored(arena, part.name, ps.ignored, diag);
    return ps.sets;
}

fn checkIgnored(arena: Allocator, part: []const u8, ignored: []const import_cura.Ignored, diag: *Diagnostic) Error!void {
    var text: std.ArrayList(u8) = .empty;
    for (ignored) |ig| if (!ig.near) try text.print(arena, "{s}{s} = {s}: {s}", .{ if (text.items.len > 0) "; " else "", ig.key, ig.value, ig.why });
    if (text.items.len > 0) return fail(diag, 0, try std.fmt.allocPrint(arena, "{s}: zslice cannot use {s}", .{ part, text.items }));
}

/// Puts the parts of `plate` on the plate of `app`, in place of its parts:
/// `count` copies of each file, each with the per-part settings of its
/// part (as "cura:" metadata), arranged on the bed. Load the profiles
/// (`plateProfiles`) and the settings (`plateSettings`) first. Returns
/// false if the parts do not all fit on the bed.
pub fn addParts(arena: Allocator, app: anytype, files: *const Files, project: *const Project, plate: Plate, diag: *Diagnostic) (Error || error{BadModel})!bool {
    const gpa = app.gpa;
    try app.clearPlate();
    for (plate.items) |item| {
        const part = &project.parts[item.part];
        var own: std.ArrayList(Pair) = .empty;
        for (part.settings) |s| if (try perPart(arena, s)) try own.append(arena, s);
        // A per-part setting that zslice cannot use stops the load.
        {
            var meta: std.ArrayList(Pair) = .empty;
            for (own.items) |s| try meta.append(arena, .{ .key = try std.fmt.allocPrint(arena, "cura:{s}", .{s.key}), .value = s.value });
            const ps = try import_cura.partSettings(arena, meta.items, &app.settings);
            try checkIgnored(arena, part.name, ps.ignored, diag);
        }
        if (part.files.len == 0) return fail(diag, 0, try std.fmt.allocPrint(arena, "{s} has no files", .{part.name}));
        for (part.files) |file| {
            const bytes = files.get(file) orelse return fail(diag, 0, try std.fmt.allocPrint(arena, "{s}: the file {s} is not in the repository", .{ part.name, file }));
            for (0..item.count) |_| {
                const first = app.plate.count();
                _ = app.addStl(std.fs.path.basename(file), bytes) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        diag.* = .{ .message = try std.fmt.allocPrint(arena, "{s}: {s} does not open ({s})", .{ part.name, file, @errorName(e) }) };
                        return error.BadModel;
                    },
                };
                // The settings of the part, then the metadata of the file
                // (a 3MF), which wins.
                for (first..app.plate.count()) |i| {
                    const old = app.plate.parts.items[i].meta;
                    var list: std.ArrayList(@TypeOf(old[0])) = .empty;
                    errdefer {
                        for (list.items) |m| {
                            gpa.free(m.key);
                            gpa.free(m.value);
                        }
                        list.deinit(gpa);
                    }
                    for (own.items) |s| {
                        const key = try std.fmt.allocPrint(gpa, "cura:{s}", .{s.key});
                        errdefer gpa.free(key);
                        try list.append(gpa, .{ .key = key, .value = try gpa.dupe(u8, s.value) });
                    }
                    for (old) |m| try list.append(gpa, .{ .key = try gpa.dupe(u8, m.key), .value = try gpa.dupe(u8, m.value) });
                    app.plate.setMeta(gpa, i, try list.toOwnedSlice(gpa));
                }
            }
        }
    }
    return app.arrangePlate();
}

/// The choices of the parts from a text "count,count,...", with one entry
/// for each part. "-" (or a missing entry) is the count of printdeck.yml,
/// and 0 leaves the part out.
pub fn choicesOf(arena: Allocator, text: []const u8, n: usize) Allocator.Error![]Choice {
    const out = try arena.alloc(Choice, n);
    @memset(out, .{});
    var it = std.mem.splitScalar(u8, text, ',');
    var i: usize = 0;
    while (it.next()) |t0| : (i += 1) {
        if (i >= n) break;
        const t = std.mem.trim(u8, t0, " ");
        if (t.len == 0 or std.mem.eql(u8, t, "-")) continue;
        const count = std.fmt.parseInt(u32, t, 10) catch continue;
        out[i] = .{ .on = count > 0, .count = count };
    }
    return out;
}

/// A parsed project and its plates.
pub const Planned = struct {
    project: Project,
    plates: []const Plate,
};

/// Parses a printdeck.yml and plans its plates with the counts of a text
/// (see `choicesOf`).
pub fn planText(arena: Allocator, text: []const u8, counts: []const u8, diag: *Diagnostic) Error!Planned {
    const p = try parse(arena, text, diag);
    const plates = try plan(arena, &p, try choicesOf(arena, counts, p.parts.len));
    return .{ .project = p, .plates = plates };
}

/// The name of a plate for a list: the name of its part, or "<first part>
/// and <n> more".
pub fn plateName(arena: Allocator, project: *const Project, plate: Plate) Allocator.Error![]const u8 {
    if (plate.items.len == 0) return "";
    const first = project.parts[plate.items[0].part].name;
    if (plate.items.len == 1) return first;
    return std.fmt.allocPrint(arena, "{s} and {d} more", .{ first, plate.items.len - 1 });
}

/// True if zslice cannot slice the plate: its profile folder has no Cura
/// stack (profiles/<folder>/cura.json). A resin plate is such a plate.
pub fn plateCannot(arena: Allocator, files: *const Files, plate: Plate) Allocator.Error!bool {
    const slash = std.mem.indexOfScalar(u8, plate.profile, '/') orelse plate.profile.len;
    const folder = plate.profile[0..slash];
    if (folder.len == 0) return true;
    return files.get(try std.fmt.allocPrint(arena, "profiles/{s}/cura.json", .{folder})) == null;
}

/// Puts plate `plate` of a planned project on the plate of `app`: the
/// settings of the plate (support, adhesion) as changes of the print, then
/// the parts (`addParts`). Load the profiles of the plate first. Returns
/// false if the parts do not all fit on the bed.
pub fn loadPlate(arena: Allocator, app: anytype, files: *const Files, planned: *const Planned, plate: Plate, diag: *Diagnostic) (Error || error{ BadModel, InvalidValue, UnknownSetting, OutOfRange })!bool {
    const sets = try plateSettings(arena, &planned.project, plate, &app.settings, diag);
    for (sets) |s| app.setSetting(s.name, s.value) catch |e| {
        diag.* = .{ .message = try std.fmt.allocPrint(arena, "{s} = {s}: {s}", .{ s.name, s.value, @errorName(e) }) };
        return e;
    };
    return addParts(arena, app, files, &planned.project, plate, diag);
}

const testing = std.testing;

const sample =
    \\project: robot
    \\parts:
    \\  - name: Feet
    \\    files: [models/foot.stl]
    \\    count: 4
    \\    printer: taz
    \\    profile: taz/pla-0.20
    \\    material: roll-4
    \\    settings: &s {support_enable: false, infill_sparse_density: 20}
    \\  - name: Arm
    \\    files: [models/arm-l.stl, models/arm-r.stl]
    \\    printer: taz
    \\    profile: taz/pla-0.20
    \\    material: roll-4
    \\    settings: {support_enable: false, infill_sparse_density: 40}
    \\  - name: Head
    \\    files: models/head.stl
    \\    printer: taz
    \\    profile: taz/pla-0.20
    \\    material: roll-4
    \\    settings: {support_enable: true}
    \\  - name: Tower
    \\    files: [models/tower.stl]
    \\    printer: taz
    \\    profile: taz/pla-0.20
    \\    material: roll-4
    \\    alone: true
    \\    variants:
    \\      - name: fine
    \\        profile: taz/pla-0.10
    \\      - name: fast
    \\        settings: {infill_sparse_density: 10}
    \\  - name: Case
    \\    files: [case.stl]
    \\    printer: phenom
    \\    prebuilt: phenom/case.cbddlp
;

test "project: parts and variants" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const p = try parse(a, sample, &diag);
    try testing.expectEqualStrings("robot", p.name);
    try testing.expectEqual(@as(usize, 6), p.parts.len);
    try testing.expectEqual(@as(u32, 4), p.parts[0].count);
    try testing.expectEqualStrings("models/head.stl", p.parts[2].files[0]);
    try testing.expectEqualStrings("Tower (fine)", p.parts[3].name);
    try testing.expectEqualStrings("pla-0.10", p.parts[3].profileName());
    try testing.expectEqualStrings("taz", p.parts[3].folder());
    try testing.expectEqualStrings("10", p.parts[4].settings[0].value);
    try testing.expect(p.parts[4].alone);
    try testing.expectEqualStrings("phenom/case.cbddlp", p.parts[5].prebuilt);
}

test "project: the plates of a plan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const p = try parse(a, sample, &diag);
    const plates = try plan(a, &p, &.{});
    // Feet and Arm share a plate: the infill can differ from part to
    // part. Head has support: its own plate. Each Tower is alone. The
    // case is on the phenom.
    try testing.expectEqual(@as(usize, 5), plates.len);
    try testing.expectEqual(@as(usize, 2), plates[0].items.len);
    try testing.expectEqual(@as(u32, 4), plates[0].items[0].count);
    try testing.expectEqual(@as(usize, 2), plates[1].items[0].part);
    try testing.expectEqualStrings("phenom", plates[4].printer);
    // A choice leaves a part out, and changes a count.
    const chosen = try plan(a, &p, &.{ .{ .count = 2 }, .{ .on = false }, .{ .on = false }, .{ .on = false }, .{ .on = false }, .{ .on = false } });
    try testing.expectEqual(@as(usize, 1), chosen.len);
    try testing.expectEqual(@as(u32, 2), chosen[0].items[0].count);
}
