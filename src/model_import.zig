//! Import a model from the page of a model site, or from a ZIP file of a
//! model: read the list of its files, and let the user choose the files to
//! load.
//!
//! The user pastes the address of a model page. The steps:
//!
//! 1. `parsePage` reads the address: a Printables model
//!    (printables.com/model/<id>-<name>) or a Thingiverse thing
//!    (thingiverse.com/thing:<id>). It gives the site, the id, and a clean
//!    page URL.
//! 2. zslice does not call the API of a site. The API of Printables is
//!    private, and the terms of Prusa forbid the automated extraction of
//!    content. The API of Thingiverse needs an app token for each call, and
//!    a token cannot be secret in an open app. So zslice shows `pageText`
//!    and opens the page in the browser. The user downloads the ZIP file of
//!    the model there ("Download all"), and opens it in zslice. `readZip`
//!    then lists that ZIP file.
//! 3. The list groups the files by kind (3MF, STL, STEP, OBJ, then the
//!    other files, which zslice does not load), and checks the files to
//!    load first (`preselect`). The shell shows the list and asks. The list
//!    is the question before the load.
//! 4. For each checked file, `zipFile` gives the bytes of its entry.
//! 5. The shell adds the files as parts on a new plate, and puts the parts
//!    that do not fit on more plates (Set.spill). It never starts a print.
//!
//! This module does no I/O. Its functions read and write text and bytes
//! that the shell gives. The contract for the shells is in
//! docs/internals/model-import.md. The forms of the page addresses come
//! from the sites (docs/references/printables.md and
//! docs/references/thingiverse.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const ol = @import("open_link.zig");
const zipfile = @import("zipfile.zig");
const root = @import("root.zig");

/// The User-Agent of each download of a file link: the app, its version,
/// and the project. No request has personal data.
pub const user_agent = "zslice/" ++ root.version ++ " (+https://github.com/beetlebugorg/zslice)";
/// The most files that one import loads.
pub const max_files = 100;
/// The most entries of a list. A ZIP file with more lists the first ones.
const max_entries = 2000;

pub const Site = enum(c_int) { none = 0, printables = 1, thingiverse = 2 };

/// The result of a step. The numbers are the C API (enum zs_import_result).
/// The numbers 4 and 9 are not used.
pub const Result = enum(c_int) {
    ok = 0,
    not_a_page = 1,
    no_api = 2,
    bad_answer = 3,
    no_files = 5,
    nothing_checked = 6,
    too_many = 7,
    too_large = 8,
    not_zip = 10,
};

/// The text for the user of each result.
pub fn message(r: Result) [:0]const u8 {
    return switch (r) {
        .ok => "",
        .not_a_page => "This is not the address of a model on Printables or Thingiverse.",
        .no_api => "zslice does not read the files of a model from the site. Open the page, and download all the files of the model as one ZIP file. Then open the ZIP file in zslice. zslice lists its files, and you choose the files to load.",
        .bad_answer => "The import did not work.",
        .no_files => "The model has no file that zslice can load (STL, 3MF, STEP, or OBJ).",
        .nothing_checked => "Check one or more files to load.",
        .too_many => "Check at most 100 files.",
        .too_large => "The checked files are larger than 512 MB together.",
        .not_zip => "The file is not a ZIP file that zslice can read.",
    };
}

/// The text for the user for a model page of a site. zslice does not call
/// the API of the site, so the user downloads the ZIP file of the model.
pub fn pageText(site: Site) [:0]const u8 {
    return switch (site) {
        .none => message(.not_a_page),
        .printables => "zslice does not read the files of a model from Printables. Open the page, and click \"Download all\" there. Printables gives one ZIP file with all the files of the model. Open that ZIP file in zslice, or drop it on the window. zslice lists its files, and you choose the files to load.",
        .thingiverse => "zslice does not read the files of a thing from Thingiverse. Open the page, and click \"Download all files\" there. Thingiverse gives one ZIP file with all the files of the thing. Open that ZIP file in zslice, or drop it on the window. zslice lists its files, and you choose the files to load.",
    };
}

/// The kind of a file. The numbers are the C API (enum zs_import_kind).
/// The list shows the kinds in this order: threemf first.
pub const Kind = enum(c_int) {
    other = 0,
    stl = 1,
    threemf = 2,
    step = 3,
    obj = 4,

    fn order(k: Kind) u8 {
        return switch (k) {
            .threemf => 0,
            .stl => 1,
            .step => 2,
            .obj => 3,
            .other => 4,
        };
    }

    pub fn label(k: Kind) [:0]const u8 {
        return switch (k) {
            .threemf => "3MF",
            .stl => "STL",
            .step => "STEP",
            .obj => "OBJ",
            .other => "Other files",
        };
    }
};

/// The kind of a file name: by its extension.
pub fn kindOf(name: []const u8) Kind {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .other;
    if (!ol.isModelName(name)) return .other;
    const ext = name[dot + 1 ..];
    if (std.ascii.eqlIgnoreCase(ext, "stl")) return .stl;
    if (std.ascii.eqlIgnoreCase(ext, "3mf")) return .threemf;
    if (std.ascii.eqlIgnoreCase(ext, "obj")) return .obj;
    return .step;
}

// ---- the address of a page ----

/// A model page: the site, the id of the model (digits), and the clean
/// URL of the page.
pub const Page = struct {
    site: Site,
    id: []const u8,
    url: []const u8,
};

/// The size of a buffer for the clean URL of a page.
pub const page_url_cap = 128;
const max_id = 12;

fn digits(text: []const u8) []const u8 {
    var n: usize = 0;
    while (n < text.len and std.ascii.isDigit(text[n])) n += 1;
    return text[0..n];
}

/// True if the text after the id ends the id: the end, `-` (a name),
/// `/`, `?`, or `#`.
fn endsId(rest: []const u8) bool {
    return rest.len == 0 or std.mem.indexOfScalar(u8, "-/?#", rest[0]) != null;
}

/// Reads the address of a model page. It takes https or http (and makes
/// it https), or no scheme. Null for other text.
///
/// - Printables: printables.com or www.printables.com, with the path
///   `/model/<id>` or `/<language>/model/<id>`, then the end or `-`, `/`,
///   `?`, or `#`.
/// - Thingiverse: thingiverse.com or www.thingiverse.com, with the path
///   `/thing:<id>`.
pub fn parsePage(text: []const u8, url_buf: []u8) ?Page {
    var rest = std.mem.trim(u8, text, " \t\r\n");
    if (rest.len > ol.max_link) return null;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (rest.len >= scheme.len and std.ascii.eqlIgnoreCase(rest[0..scheme.len], scheme)) {
            rest = rest[scheme.len..];
            break;
        }
    }
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..host_end];
    var path = rest[host_end..];
    if (std.mem.indexOfAny(u8, path, "?#")) |q| path = path[0..q];
    const site: Site = if (eqlAny(host, &.{ "printables.com", "www.printables.com" }))
        .printables
    else if (eqlAny(host, &.{ "thingiverse.com", "www.thingiverse.com" }))
        .thingiverse
    else
        return null;
    switch (site) {
        .printables => {
            if (!std.mem.startsWith(u8, path, "/")) return null;
            var p = path[1..];
            // A language: two letters, or two letters, a dash, and two more.
            if (std.mem.indexOfScalar(u8, p, '/')) |slash| {
                const lang = p[0..slash];
                if ((lang.len == 2 or lang.len == 5) and !std.mem.eql(u8, lang, "model")) {
                    for (lang, 0..) |c, i| {
                        if (!(std.ascii.isAlphabetic(c) or (i == 2 and c == '-'))) return null;
                    }
                    p = p[slash + 1 ..];
                }
            }
            if (!std.mem.startsWith(u8, p, "model/")) return null;
            const id = digits(p[6..]);
            if (id.len == 0 or id.len > max_id or !endsId(p[6 + id.len ..])) return null;
            const url = std.fmt.bufPrint(url_buf, "https://www.printables.com/model/{s}", .{id}) catch return null;
            return .{ .site = .printables, .id = id, .url = url };
        },
        .thingiverse => {
            if (!std.mem.startsWith(u8, path, "/thing:")) return null;
            const id = digits(path[7..]);
            if (id.len == 0 or id.len > max_id or !endsId(path[7 + id.len ..])) return null;
            const url = std.fmt.bufPrint(url_buf, "https://www.thingiverse.com/thing:{s}", .{id}) catch return null;
            return .{ .site = .thingiverse, .id = id, .url = url };
        },
        .none => unreachable,
    }
}

fn eqlAny(text: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.ascii.eqlIgnoreCase(text, o)) return true;
    return false;
}

// ---- the list ----

/// A file of the model.
pub const Entry = struct {
    /// The file name: no folder, no control character (open_link.cleanName).
    name: [:0]const u8,
    /// The folder of the file in the ZIP file, or "".
    folder: [:0]const u8 = "",
    /// Why the file does not load, or a note for the user, or "".
    note: [:0]const u8 = "",
    size: u64,
    kind: Kind,
    can_load: bool,
    checked: bool = false,
    /// The plates of a 3MF file (Bambu Studio and OrcaSlicer projects),
    /// or 0 when the list does not know.
    plates: u32 = 0,
    /// The index of the entry in the ZIP file.
    zip_index: u32 = 0,
};

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    site: Site = .none,
    title: [:0]const u8 = "",
    author: [:0]const u8 = "",
    license: [:0]const u8 = "",
    /// The page of the model, or "".
    page_url: [:0]const u8 = "",
    /// A note on the list for the user, or "".
    note: [:0]const u8 = "",
    entries: []Entry = &.{},

    pub fn deinit(l: *List) void {
        l.arena.deinit();
    }

    /// Checks or unchecks entry i. A file that does not load stays
    /// unchecked.
    pub fn check(l: *List, i: usize, on: bool) error{OutOfRange}!void {
        if (i >= l.entries.len) return error.OutOfRange;
        l.entries[i].checked = on and l.entries[i].can_load;
    }

    pub const Sum = struct { files: usize, bytes: u64 };

    pub fn sum(l: *const List) Sum {
        var s: Sum = .{ .files = 0, .bytes = 0 };
        for (l.entries) |e| if (e.checked) {
            s.files += 1;
            s.bytes +|= e.size;
        };
        return s;
    }

    /// The check before the download: one or more files, at most
    /// max_files, and at most open_link.max_bytes together.
    pub fn ready(l: *const List) Result {
        const s = l.sum();
        if (s.files == 0) return .nothing_checked;
        if (s.files > max_files) return .too_many;
        if (s.bytes > ol.max_bytes) return .too_large;
        return .ok;
    }
};

/// A copy of text with no control character and at most `max` bytes (at
/// a UTF-8 boundary). Empty for text that is not UTF-8.
fn plainText(a: Allocator, text: []const u8, max: usize) Allocator.Error![:0]const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return "";
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (out.items.len >= max) break;
        try out.append(a, if (c < 0x20 or c == 0x7F) ' ' else c);
    }
    var n = out.items.len;
    while (n > 0 and !std.unicode.utf8ValidateSlice(out.items[0..n])) n -= 1;
    out.shrinkRetainingCapacity(n);
    return out.toOwnedSliceSentinel(a, 0);
}

fn cleanName(a: Allocator, raw: []const u8) Allocator.Error![:0]const u8 {
    var buf: [ol.name_cap]u8 = undefined;
    const name = ol.cleanName(raw, &buf);
    return a.dupeSentinel(u8, name, 0);
}

/// The plates of a 3MF file: the <plate> elements of the
/// Metadata/model_settings.config of Bambu Studio and OrcaSlicer. 1 for a
/// 3MF file with no plates there, 0 for bytes that are not a 3MF file.
pub fn plates3mf(gpa: Allocator, bytes: []const u8) Allocator.Error!u32 {
    const infos = zipfile.directory(gpa, bytes, ol.max_bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => 0,
    };
    defer gpa.free(infos);
    var model = false;
    for (infos) |info| {
        if (std.mem.startsWith(u8, info.name, "3D/") and std.mem.endsWith(u8, info.name, ".model")) model = true;
    }
    if (!model) return 0;
    for (infos) |info| {
        if (!std.mem.eql(u8, info.name, "Metadata/model_settings.config")) continue;
        if (info.size > 64 << 20) return 1;
        const text = zipfile.extract(gpa, bytes, info) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => 1,
        };
        defer gpa.free(text);
        var n: u32 = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "<plate>")) |p| {
            n += 1;
            at = p + 7;
        }
        return @max(n, 1);
    }
    return 1;
}

/// The list of the files of a ZIP file (for example the "Download all
/// files" ZIP of a Thingiverse thing or of a Printables model). The names
/// keep no folder; the folder is a field. Entries of macOS
/// (`__MACOSX/`, `._name`) do not show.
pub fn readZip(gpa: Allocator, bytes: []const u8) error{ OutOfMemory, NotZip, NoFiles }!List {
    const infos = zipfile.directory(gpa, bytes, std.math.maxInt(u64)) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NotZip,
    };
    defer gpa.free(infos);
    var list: List = .{ .arena = .init(gpa) };
    errdefer list.deinit();
    const a = list.arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    for (infos, 0..) |info, index| {
        if (entries.items.len >= max_entries) break;
        if (std.mem.startsWith(u8, info.name, "__MACOSX/")) continue;
        const slash = std.mem.lastIndexOfAny(u8, info.name, "/\\");
        const base = if (slash) |s| info.name[s + 1 ..] else info.name;
        if (std.mem.startsWith(u8, base, "._")) continue;
        const name = try cleanName(a, base);
        if (name.len == 0) continue;
        const kind = kindOf(name);
        var e: Entry = .{
            .name = name,
            .folder = if (slash) |s| try plainText(a, info.name[0..s], 200) else "",
            .size = info.size,
            .kind = kind,
            .can_load = kind != .other and info.size <= ol.max_bytes,
            .zip_index = @intCast(index),
        };
        if (kind == .other) {
            e.note = "zslice does not load this kind of file.";
        } else if (info.size > ol.max_bytes) {
            e.note = "The file is larger than 512 MB.";
        } else if (kind == .threemf) {
            const data = zipfile.extract(gpa, bytes, info) catch null;
            if (data) |d| {
                defer gpa.free(d);
                e.plates = try plates3mf(gpa, d);
            }
        }
        try entries.append(a, e);
    }
    list.entries = try entries.toOwnedSlice(a);
    try finish(&list);
    return list;
}

/// The bytes of entry i of a list of `readZip`, from the same ZIP bytes.
/// The caller owns them.
pub fn zipFile(gpa: Allocator, list: *const List, bytes: []const u8, i: usize) error{ OutOfMemory, OutOfRange, NotZip }![]u8 {
    if (i >= list.entries.len or list.site != .none) return error.OutOfRange;
    const e = list.entries[i];
    if (!e.can_load) return error.OutOfRange;
    const infos = zipfile.directory(gpa, bytes, std.math.maxInt(u64)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NotZip,
    };
    defer gpa.free(infos);
    if (e.zip_index >= infos.len) return error.NotZip;
    return zipfile.extract(gpa, bytes, infos[e.zip_index]) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NotZip,
    };
}

/// Sorts the entries by kind (the ZIP order stays in a kind), refuses
/// a list with no file to load, and checks the files to load first.
fn finish(list: *List) error{ OutOfMemory, NoFiles }!void {
    std.mem.sort(Entry, list.entries, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return x.kind.order() < y.kind.order();
        }
    }.lt);
    // std.mem.sort is stable (a block sort): the order of the ZIP file stays.
    var any = false;
    for (list.entries) |e| any = any or e.can_load;
    if (!any) return error.NoFiles;
    for (list.entries) |*e| {
        if (e.can_load and e.size > ol.max_bytes) {
            e.can_load = false;
            e.note = "The file is larger than 512 MB.";
        }
    }
    try preselect(list);
}

fn baseName(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

/// The files to load first:
///
/// - Each file that loads, with these exceptions.
/// - A STEP file with the base name of a mesh file (STL, 3MF, or OBJ):
///   the mesh is the same part, and it loads faster.
/// - The 3MF files, when the model also has STL or OBJ files: a 3MF file
///   of a model site often holds the same parts on plates. The list says
///   so, and the user can check the 3MF file.
/// - At most max_files files.
fn preselect(list: *List) Allocator.Error!void {
    const a = list.arena.allocator();
    var meshes: usize = 0;
    var threemf: usize = 0;
    for (list.entries) |e| {
        if (!e.can_load) continue;
        if (e.kind == .stl or e.kind == .obj) meshes += 1;
        if (e.kind == .threemf) threemf += 1;
    }
    var checked: usize = 0;
    for (list.entries) |*e| {
        e.checked = false;
        if (!e.can_load) continue;
        if (e.kind == .threemf and meshes > 0) continue;
        if (e.kind == .step) {
            var same = false;
            for (list.entries) |o| {
                if (o.kind == .step or o.kind == .other) continue;
                if (std.ascii.eqlIgnoreCase(baseName(o.name), baseName(e.name))) same = true;
            }
            if (same) {
                e.note = "A mesh file of this part is in the list.";
                continue;
            }
        }
        if (checked >= max_files) continue;
        e.checked = true;
        checked += 1;
    }
    if (threemf > 0 and meshes > 0) {
        list.note = try a.dupeSentinel(u8, "This model has 3MF files and STL or OBJ files. They often hold the same parts, so zslice checks the STL and OBJ files only. Check a 3MF file to load it too.", 0);
    }
}

// ---- tests ----

const testing = std.testing;

test "the address of a model page" {
    var buf: [page_url_cap]u8 = undefined;
    var p = parsePage("https://www.printables.com/model/3161-3d-benchy/files", &buf).?;
    try testing.expectEqual(Site.printables, p.site);
    try testing.expectEqualStrings("3161", p.id);
    try testing.expectEqualStrings("https://www.printables.com/model/3161", p.url);
    p = parsePage("  printables.com/de/model/42?lang=de#x ", &buf).?;
    try testing.expectEqualStrings("42", p.id);
    p = parsePage("HTTP://Printables.com/model/7", &buf).?;
    try testing.expectEqualStrings("7", p.id);
    p = parsePage("https://www.thingiverse.com/thing:763622/files", &buf).?;
    try testing.expectEqual(Site.thingiverse, p.site);
    try testing.expectEqualStrings("763622", p.id);
    try testing.expectEqualStrings("https://www.thingiverse.com/thing:763622", p.url);
    const refused = [_][]const u8{
        "https://www.printables.com/",
        "https://www.printables.com/model/",
        "https://www.printables.com/model/abc",
        "https://www.printables.com/model/12x",
        "https://printables.com.evil.test/model/1",
        "https://evil.test/printables.com/model/1",
        "https://www.printables.com/@user/models",
        "https://www.printables.com/xyz/model/1",
        "https://www.thingiverse.com/thing:",
        "https://www.thingiverse.com/thing:1a",
        "https://www.thingiverse.com/things/1",
        "ftp://www.thingiverse.com/thing:1",
        "https://www.printables.com/model/1234567890123",
        "",
    };
    for (refused) |t| {
        if (parsePage(t, &buf) != null) {
            std.debug.print("accepted: {s}\n", .{t});
            return error.TestUnexpectedResult;
        }
    }
}

fn testZip(gpa: Allocator, entries: []const zipfile.Entry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try zipfile.write(gpa, &aw.writer, entries);
    return aw.toOwnedSlice();
}

test "the files of a ZIP file, with the plates of a 3MF file" {
    const gpa = testing.allocator;
    const plates =
        \\<config><plate><metadata key="plater_id" value="1"/></plate>
        \\<plate><metadata key="plater_id" value="2"/></plate>
        \\<plate><metadata key="plater_id" value="3"/></plate></config>
    ;
    const inner = try testZip(gpa, &.{
        .{ .name = "3D/3dmodel.model", .data = @constCast("<model/>") },
        .{ .name = "Metadata/model_settings.config", .data = @constCast(plates) },
    });
    defer gpa.free(inner);
    try testing.expectEqual(@as(u32, 3), try plates3mf(gpa, inner));
    try testing.expectEqual(@as(u32, 0), try plates3mf(gpa, "solid x"));

    const outer = try testZip(gpa, &.{
        .{ .name = "README.txt", .data = @constCast("hi") },
        .{ .name = "files/cube.stl", .data = @constCast("solid cube\nendsolid cube\n") },
        .{ .name = "files/plates.3mf", .data = inner },
        .{ .name = "__MACOSX/files/._cube.stl", .data = @constCast("x") },
        .{ .name = "images/cube.png", .data = @constCast("png") },
    });
    defer gpa.free(outer);
    var list = try readZip(gpa, outer);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 4), list.entries.len);
    try testing.expectEqualStrings("plates.3mf", list.entries[0].name);
    try testing.expectEqual(@as(u32, 3), list.entries[0].plates);
    // The ZIP file has an STL file too, so the 3MF file is not checked.
    try testing.expect(!list.entries[0].checked);
    try testing.expectEqualStrings("cube.stl", list.entries[1].name);
    try testing.expectEqualStrings("files", list.entries[1].folder);
    try testing.expect(list.entries[1].checked);
    try testing.expect(!list.entries[2].can_load);
    const data = try zipFile(gpa, &list, outer, 1);
    defer gpa.free(data);
    try testing.expectEqualStrings("solid cube\nendsolid cube\n", data);
    try testing.expectError(error.OutOfRange, zipFile(gpa, &list, outer, 2));
    try testing.expectError(error.NotZip, readZip(gpa, "not a zip at all, and long enough to look"));
}

test "a STEP file next to its STL file is not checked" {
    const gpa = testing.allocator;
    const z = try testZip(gpa, &.{
        .{ .name = "a.step", .data = @constCast("ISO") },
        .{ .name = "A.stl", .data = @constCast("solid") },
        .{ .name = "b.step", .data = @constCast("ISO") },
    });
    defer gpa.free(z);
    var list = try readZip(gpa, z);
    defer list.deinit();
    try testing.expectEqualStrings("A.stl", list.entries[0].name);
    try testing.expect(list.entries[0].checked);
    try testing.expectEqualStrings("a.step", list.entries[1].name);
    try testing.expect(!list.entries[1].checked);
    try testing.expect(list.entries[1].note.len > 0);
    try testing.expect(list.entries[2].checked);
}

test "the text for a model page names the site and the ZIP file" {
    for ([_]Site{ .printables, .thingiverse }, [_][]const u8{ "Printables", "Thingiverse" }) |site, name| {
        const t = pageText(site);
        try testing.expect(std.mem.indexOf(u8, t, name) != null);
        try testing.expect(std.mem.indexOf(u8, t, "ZIP file") != null);
        try testing.expect(std.mem.indexOf(u8, t, "Download all") != null);
    }
}

test "the kinds of files" {
    try testing.expectEqual(Kind.stl, kindOf("a.STL"));
    try testing.expectEqual(Kind.threemf, kindOf("a.3mf"));
    try testing.expectEqual(Kind.step, kindOf("a.stp"));
    try testing.expectEqual(Kind.obj, kindOf("a.obj"));
    try testing.expectEqual(Kind.other, kindOf("a.zip"));
    try testing.expectEqual(Kind.other, kindOf(".stl"));
    try testing.expect(std.mem.startsWith(u8, user_agent, "zslice/"));
}
