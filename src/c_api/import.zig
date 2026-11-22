//! The C API of the import of a model from a model page or a ZIP file
//! (src/model_import.zig): the page address, the text for a page, the
//! list of the files of a ZIP file, the choice of the user, and the files
//! of the ZIP file. zslice calls no API of a site. All apps call these, so that they share one
//! set of rules. See zslice.h and docs/internals/model-import.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const mi = zs.model_import;
const Result = mi.Result;
const gpa = c.gpa;

/// struct zs_import_page of zslice.h.
pub const Page = extern struct {
    site: c_int,
    id: [32]u8,
    url: [mi.page_url_cap]u8,
};

/// struct zs_import_info of zslice.h.
pub const Info = extern struct {
    site: c_int,
    title: [*:0]const u8,
    author: [*:0]const u8,
    license: [*:0]const u8,
    page_url: [*:0]const u8,
    note: [*:0]const u8,
};

/// struct zs_import_file of zslice.h.
pub const File = extern struct {
    name: [*:0]const u8,
    folder: [*:0]const u8,
    note: [*:0]const u8,
    kind_label: [*:0]const u8,
    size: u64,
    kind: c_int,
    can_load: c_int,
    checked: c_int,
    plates: c_int,
};

fn code(r: Result) c_int {
    return @intFromEnum(r);
}

fn span(s: ?[*:0]const u8) []const u8 {
    return if (s) |p| std.mem.span(p) else "";
}

fn put(field: []u8, text: []const u8) void {
    const n = @min(text.len, field.len - 1);
    @memcpy(field[0..n], text[0..n]);
    field[n] = 0;
}

/// Reads the address of a model page into out. ZS_IMPORT_NOT_A_PAGE for
/// other text.
export fn zs_import_page_check(text: ?[*:0]const u8, out: ?*Page) c_int {
    const o = out orelse return code(.not_a_page);
    o.site = 0;
    o.id[0] = 0;
    o.url[0] = 0;
    var buf: [mi.page_url_cap]u8 = undefined;
    const p = mi.parsePage(span(text), &buf) orelse return code(.not_a_page);
    o.site = @intFromEnum(p.site);
    put(&o.id, p.id);
    put(&o.url, p.url);
    return code(.ok);
}

/// The User-Agent of each download of a file link.
export fn zs_import_user_agent() [*:0]const u8 {
    return mi.user_agent;
}

/// The text for the user for a model page of a site (enum
/// zs_import_site): open the page, download the ZIP file of the model,
/// and open it in zslice.
export fn zs_import_page_text(site: c_int) [*:0]const u8 {
    const s = std.enums.fromInt(mi.Site, site) orelse .none;
    return mi.pageText(s).ptr;
}

/// Lists the files of a ZIP file into a new list. Keep the bytes for
/// zs_import_zip_file. Free the list with zs_import_list_free.
export fn zs_import_list_zip(bytes: ?[*]const u8, len: usize, out: ?*?*mi.List) c_int {
    const o = out orelse return code(.not_zip);
    o.* = null;
    const data: []const u8 = if (len == 0) "" else (bytes orelse return code(.not_zip))[0..len];
    const l = gpa.create(mi.List) catch return code(.not_zip);
    l.* = mi.readZip(gpa, data) catch |e| {
        gpa.destroy(l);
        return code(switch (e) {
            error.NoFiles => .no_files,
            error.OutOfMemory, error.NotZip => .not_zip,
        });
    };
    o.* = l;
    return code(.ok);
}

export fn zs_import_list_free(list: ?*mi.List) void {
    const l = list orelse return;
    l.deinit();
    gpa.destroy(l);
}

/// The facts of the model of the list. The strings stay valid until
/// zs_import_list_free.
export fn zs_import_list_info(list: ?*const mi.List, out: ?*Info) c_int {
    const l = list orelse return code(.bad_answer);
    const o = out orelse return code(.bad_answer);
    o.* = .{ .site = @intFromEnum(l.site), .title = l.title.ptr, .author = l.author.ptr, .license = l.license.ptr, .page_url = l.page_url.ptr, .note = l.note.ptr };
    return code(.ok);
}

export fn zs_import_count(list: ?*const mi.List) usize {
    const l = list orelse return 0;
    return l.entries.len;
}

/// File i of the list. The strings stay valid until zs_import_list_free.
export fn zs_import_file_get(list: ?*const mi.List, i: usize, out: ?*File) c_int {
    const l = list orelse return code(.bad_answer);
    const o = out orelse return code(.bad_answer);
    if (i >= l.entries.len) return code(.bad_answer);
    const e = l.entries[i];
    o.* = .{
        .name = e.name.ptr,
        .folder = e.folder.ptr,
        .note = e.note.ptr,
        .kind_label = e.kind.label().ptr,
        .size = e.size,
        .kind = @intFromEnum(e.kind),
        .can_load = @intFromBool(e.can_load),
        .checked = @intFromBool(e.checked),
        .plates = @intCast(@min(e.plates, 1 << 20)),
    };
    return code(.ok);
}

/// Checks (on != 0) or unchecks file i. A file that does not load stays
/// unchecked.
export fn zs_import_check(list: ?*mi.List, i: usize, on: c_int) c_int {
    const l = list orelse return code(.bad_answer);
    l.check(i, on != 0) catch return code(.bad_answer);
    return code(.ok);
}

/// The checked files and their bytes together, and if the list is ready
/// for the download: ZS_IMPORT_OK, ZS_IMPORT_NOTHING_CHECKED,
/// ZS_IMPORT_TOO_MANY, or ZS_IMPORT_TOO_LARGE.
export fn zs_import_ready(list: ?*const mi.List, files: ?*usize, bytes: ?*u64) c_int {
    const l = list orelse return code(.nothing_checked);
    const s = l.sum();
    if (files) |p| p.* = s.files;
    if (bytes) |p| p.* = s.bytes;
    return code(l.ready());
}

/// The bytes of file i of a list of zs_import_list_zip, from the same ZIP
/// bytes. Free them with zs_buffer_free.
export fn zs_import_zip_file(list: ?*const mi.List, bytes: ?[*]const u8, len: usize, i: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const l = list orelse return code(.not_zip);
    const o = out orelse return code(.not_zip);
    const ol_ = out_len orelse return code(.not_zip);
    const data: []const u8 = if (len == 0) "" else (bytes orelse return code(.not_zip))[0..len];
    const file = mi.zipFile(gpa, l, data, i) catch return code(.not_zip);
    o.* = file.ptr;
    ol_.* = file.len;
    return code(.ok);
}

/// The plates of a 3MF file (Bambu Studio and OrcaSlicer projects): 1 for
/// a 3MF file with no plates, 0 for bytes that are not a 3MF file.
export fn zs_import_3mf_plates(bytes: ?[*]const u8, len: usize) c_int {
    if (len == 0) return 0;
    const data = (bytes orelse return 0)[0..len];
    const n = mi.plates3mf(gpa, data) catch return 0;
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

/// The text for the user of an enum zs_import_result.
export fn zs_import_message(result: c_int) [*:0]const u8 {
    const r = std.enums.fromInt(Result, result) orelse return "The import did not work.";
    return mi.message(r).ptr;
}

/// The limits and the sizes of the structs, for a shell with no C header
/// (the web app). Each pointer can be NULL.
export fn zs_import_limits(max_files: ?*usize, page_size: ?*usize, file_size: ?*usize) void {
    if (max_files) |p| p.* = mi.max_files;
    if (page_size) |p| p.* = @sizeOf(Page);
    if (file_size) |p| p.* = @sizeOf(File);
}

test "C API: a page, the text for a page, a ZIP list, and a check" {
    var page: Page = undefined;
    try std.testing.expectEqual(code(.ok), zs_import_page_check("https://www.printables.com/model/9-box", &page));
    try std.testing.expectEqualStrings("9", std.mem.sliceTo(&page.id, 0));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zs_import_page_text(page.site)), "Printables") != null);
    try std.testing.expectEqual(code(.ok), zs_import_page_check("thingiverse.com/thing:5", &page));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zs_import_page_text(page.site)), "Thingiverse") != null);
    try std.testing.expectEqual(code(.not_a_page), zs_import_page_check("https://example.com/", &page));
    try std.testing.expectEqualStrings(mi.message(.not_a_page), std.mem.span(zs_import_page_text(99)));

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try zs.zipfile.write(std.testing.allocator, &aw.writer, &.{
        .{ .name = "a.stl", .data = @constCast("solid a\nendsolid a\n") },
        .{ .name = "b.stl", .data = @constCast("solid b\nendsolid b\n") },
    });
    const zip = aw.written();
    var list: ?*mi.List = null;
    try std.testing.expectEqual(code(.ok), zs_import_list_zip(zip.ptr, zip.len, &list));
    defer zs_import_list_free(list);
    try std.testing.expectEqual(@as(usize, 2), zs_import_count(list));
    var f: File = undefined;
    try std.testing.expectEqual(code(.ok), zs_import_file_get(list, 0, &f));
    try std.testing.expectEqualStrings("a.stl", std.mem.span(f.name));
    try std.testing.expectEqualStrings("STL", std.mem.span(f.kind_label));
    try std.testing.expectEqual(@as(c_int, 1), f.checked);
    var files: usize = 0;
    var bytes: u64 = 0;
    try std.testing.expectEqual(code(.ok), zs_import_ready(list, &files, &bytes));
    try std.testing.expectEqual(@as(usize, 2), files);
    _ = zs_import_check(list, 0, 0);
    _ = zs_import_check(list, 1, 0);
    try std.testing.expectEqual(code(.nothing_checked), zs_import_ready(list, null, null));
    try std.testing.expectEqualStrings("The import did not work.", std.mem.span(zs_import_message(99)));
    try std.testing.expectEqualStrings("The import did not work.", std.mem.span(zs_import_message(4)));
}
