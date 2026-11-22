//! The C API of the import of a model from a model page or a ZIP file
//! (src/model_import.zig): the page address, the requests to the site,
//! the list of files and the choice of the user, the download links, and
//! the files of a ZIP file. All apps call these, so that they share one
//! set of rules. See zslice.h and docs/internals/model-import.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const mi = zs.model_import;
const ol = zs.open_link;
const link_api = @import("link.zig");
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
    preview: [*:0]const u8,
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

fn pageOf(p: *const Page) ?mi.Page {
    const site = std.enums.fromInt(mi.Site, p.site) orelse return null;
    if (site == .none) return null;
    return .{ .site = site, .id = std.mem.sliceTo(&p.id, 0), .url = std.mem.sliceTo(&p.url, 0) };
}

fn copyOut(text: []const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) void {
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
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

/// The User-Agent of each request of an import.
export fn zs_import_user_agent() [*:0]const u8 {
    return mi.user_agent;
}

/// The URL of the API of a site for a POST of zs_import_files_request:
/// the GraphQL endpoint of Printables, or "" for a site with no API that
/// zslice can use (Thingiverse).
export fn zs_import_api_url(site: c_int) [*:0]const u8 {
    return if (site == @intFromEnum(mi.Site.printables)) mi.printables_api else "";
}

/// The body (JSON) of the POST that asks the site for the list of files.
/// ZS_IMPORT_NO_API for Thingiverse. The same buffer rules as
/// zs_app_setting_get.
export fn zs_import_files_request(page: ?*const Page, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const pg = pageOf(page orelse return code(.not_a_page)) orelse return code(.not_a_page);
    if (pg.site != .printables) return code(.no_api);
    const body = mi.filesRequest(gpa, pg.id) catch return code(.bad_answer);
    defer gpa.free(body);
    copyOut(body, buf, cap, out_len);
    return code(.ok);
}

/// Reads the answer of the site to zs_import_files_request into a new
/// list. Free it with zs_import_list_free.
export fn zs_import_list_read(page: ?*const Page, json: ?[*]const u8, len: usize, out: ?*?*mi.List) c_int {
    const o = out orelse return code(.bad_answer);
    o.* = null;
    const pg = pageOf(page orelse return code(.not_a_page)) orelse return code(.not_a_page);
    if (pg.site != .printables) return code(.no_api);
    const text: []const u8 = if (len == 0) "" else (json orelse return code(.bad_answer))[0..len];
    const l = gpa.create(mi.List) catch return code(.bad_answer);
    l.* = mi.readPrintables(gpa, text, pg) catch |e| {
        gpa.destroy(l);
        return code(switch (e) {
            error.NotFound => .not_found,
            error.NoFiles => .no_files,
            error.OutOfMemory, error.BadAnswer => .bad_answer,
        });
    };
    o.* = l;
    return code(.ok);
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
        .preview = e.preview.ptr,
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

/// The body (JSON) of the POST to zs_import_api_url that asks for the
/// download link of file i. The same buffer rules as zs_app_setting_get.
export fn zs_import_link_request(list: ?*const mi.List, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const l = list orelse return code(.bad_answer);
    const body = mi.linkRequest(gpa, l, i) catch return code(.no_api);
    defer gpa.free(body);
    copyOut(body, buf, cap, out_len);
    return code(.ok);
}

/// Reads the answer to zs_import_link_request into a checked link: an
/// https URL on printables.com, with the name of file i. Download it as
/// a zs_link (docs/internals/open-links.md, steps 1 to 9).
export fn zs_import_link_read(list: ?*const mi.List, i: usize, json: ?[*]const u8, len: usize, out: ?*link_api.Link) c_int {
    const l = list orelse return code(.bad_answer);
    const o = out orelse return code(.bad_answer);
    o.url[0] = 0;
    o.host[0] = 0;
    o.name[0] = 0;
    const text: []const u8 = if (len == 0) "" else (json orelse return code(.bad_answer))[0..len];
    var b: ol.Buffers = .{};
    const got = mi.readLink(text, l, i, &b) catch |e| return code(switch (e) {
        error.BadAnswer, error.OutOfRange => .bad_answer,
        error.NotFound => .not_found,
        error.BadLink => .bad_link,
    });
    put(&o.url, got.url);
    put(&o.host, got.host);
    put(&o.name, got.name);
    return code(.ok);
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
export fn zs_import_limits(max_answer: ?*u64, max_preview: ?*u64, max_files: ?*usize, page_size: ?*usize, file_size: ?*usize) void {
    if (max_answer) |p| p.* = mi.max_answer;
    if (max_preview) |p| p.* = mi.max_preview;
    if (max_files) |p| p.* = mi.max_files;
    if (page_size) |p| p.* = @sizeOf(Page);
    if (file_size) |p| p.* = @sizeOf(File);
}

test "C API: a page, a list, a check, and a link" {
    var page: Page = undefined;
    try std.testing.expectEqual(code(.ok), zs_import_page_check("https://www.printables.com/model/9-box", &page));
    try std.testing.expectEqualStrings("9", std.mem.sliceTo(&page.id, 0));
    var len: usize = 0;
    try std.testing.expectEqual(code(.ok), zs_import_files_request(&page, null, 0, &len));
    const body = try std.testing.allocator.alloc(u8, len + 1);
    defer std.testing.allocator.free(body);
    _ = zs_import_files_request(&page, body.ptr, body.len, null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"9\"") != null);

    const answer =
        \\{"data":{"model":{"id":"9","name":"Box","stls":[{"id":"1","name":"a.stl","fileSize":10,"filePreviewPath":"media/a.png"},{"id":"2","name":"b.stl","fileSize":20}],"otherFiles":[]}}}
    ;
    var list: ?*mi.List = null;
    try std.testing.expectEqual(code(.ok), zs_import_list_read(&page, answer.ptr, answer.len, &list));
    defer zs_import_list_free(list);
    try std.testing.expectEqual(@as(usize, 2), zs_import_count(list));
    var f: File = undefined;
    try std.testing.expectEqual(code(.ok), zs_import_file_get(list, 0, &f));
    try std.testing.expectEqualStrings("a.stl", std.mem.span(f.name));
    try std.testing.expectEqualStrings("STL", std.mem.span(f.kind_label));
    try std.testing.expectEqualStrings("https://media.printables.com/media/a.png", std.mem.span(f.preview));
    try std.testing.expectEqual(@as(c_int, 1), f.checked);
    var files: usize = 0;
    var bytes: u64 = 0;
    try std.testing.expectEqual(code(.ok), zs_import_ready(list, &files, &bytes));
    try std.testing.expectEqual(@as(usize, 2), files);
    try std.testing.expectEqual(@as(u64, 30), bytes);
    _ = zs_import_check(list, 0, 0);
    _ = zs_import_check(list, 1, 0);
    try std.testing.expectEqual(code(.nothing_checked), zs_import_ready(list, null, null));

    const l = try std.testing.allocator.create(link_api.Link);
    defer std.testing.allocator.destroy(l);
    const reply = "{\"data\":{\"getDownloadLink\":{\"ok\":true,\"output\":{\"link\":\"https://files.printables.com/media/b.stl\"}}}}";
    try std.testing.expectEqual(code(.ok), zs_import_link_read(list, 1, reply.ptr, reply.len, l));
    try std.testing.expectEqualStrings("b.stl", std.mem.sliceTo(&l.name, 0));

    try std.testing.expectEqual(code(.ok), zs_import_page_check("thingiverse.com/thing:5", &page));
    try std.testing.expectEqual(code(.no_api), zs_import_files_request(&page, null, 0, &len));
    try std.testing.expectEqualStrings("", std.mem.span(zs_import_api_url(page.site)));
    try std.testing.expectEqual(code(.not_a_page), zs_import_page_check("https://example.com/", &page));
    try std.testing.expectEqualStrings("The import did not work.", std.mem.span(zs_import_message(99)));
}
