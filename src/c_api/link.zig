//! The C API of the links that open a model (src/open_link.zig): the check
//! of a link, of each redirect, of the head of the answer, and of each
//! address. All apps call these, so that they share one set of rules. See
//! zslice.h.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const ol = zs.open_link;
const Result = ol.Result;

/// struct zs_link of zslice.h.
pub const Link = extern struct {
    url: [ol.url_cap]u8,
    host: [ol.host_cap]u8,
    name: [ol.name_cap]u8,
};

fn code(r: Result) c_int {
    return @intFromEnum(r);
}

fn span(s: ?[*:0]const u8) []const u8 {
    return if (s) |p| std.mem.span(p) else "";
}

/// Copies text and a NUL byte into a field of the link.
fn put(field: []u8, text: []const u8) void {
    const n = @min(text.len, field.len - 1);
    std.mem.copyForwards(u8, field[0..n], text[0..n]);
    field[n] = 0;
}

fn fill(out: *Link, l: ol.Link) void {
    put(&out.url, l.url);
    put(&out.host, l.host);
    put(&out.name, l.name);
}

fn clear(out: *Link) void {
    out.url[0] = 0;
    out.host[0] = 0;
    out.name[0] = 0;
}

/// Reads a link: zslice://open?file=<URL> or web+zslice://open?file=<URL>.
export fn zs_link_check(text: ?[*:0]const u8, out: ?*Link) c_int {
    const o = out orelse return code(.not_a_link);
    clear(o);
    var b: ol.Buffers = .{};
    return switch (ol.parse(span(text), &b)) {
        .ok => |l| blk: {
            fill(o, l);
            break :blk code(.ok);
        },
        .refused => |r| code(r),
    };
}

/// Checks a plain https URL of a model file (the ?open= of the web app).
export fn zs_link_check_url(url: ?[*:0]const u8, out: ?*Link) c_int {
    const o = out orelse return code(.not_public);
    clear(o);
    var b: ol.Buffers = .{};
    return switch (ol.checkModelUrl(span(url), &b)) {
        .ok => |l| blk: {
            fill(o, l);
            break :blk code(.ok);
        },
        .refused => |r| code(r),
    };
}

/// Follows a redirect: link->url and link->host become the checked URL of
/// `location`. The name stays.
export fn zs_link_redirect(location: ?[*:0]const u8, link: ?*Link) c_int {
    const l = link orelse return code(.bad_redirect);
    var b: ol.Buffers = .{};
    const from = std.mem.sliceTo(&l.url, 0);
    const next = ol.redirect(span(location), from, &b) orelse return code(.bad_redirect);
    put(&l.url, next.url);
    put(&l.host, next.host);
    return code(.ok);
}

/// Checks the head of an answer. length: -1 when the answer has none.
export fn zs_link_check_reply(content_type: ?[*:0]const u8, length: i64) c_int {
    return code(ol.checkReply(span(content_type), length));
}

/// Sets link->name to the name of the download.
export fn zs_link_file_name(disposition: ?[*:0]const u8, link: ?*Link) c_int {
    const l = link orelse return code(.not_a_model);
    var b: ol.Buffers = .{};
    const name = ol.fileName(span(disposition), std.mem.sliceTo(&l.url, 0), std.mem.sliceTo(&l.name, 0), &b);
    put(&l.name, name);
    return code(if (name.len == 0) .not_a_model else .ok);
}

/// The URL of the link (link->url), for a language that cannot read the
/// long array of the struct (Swift imports no C array this long).
export fn zs_link_url(link: ?*const Link) [*:0]const u8 {
    const l = link orelse return "";
    return @ptrCast(&l.url);
}

/// Sets the URL of the link (link->url), for example to the final URL
/// after the redirects, before zs_link_file_name.
export fn zs_link_set_url(link: ?*Link, url: ?[*:0]const u8) void {
    const l = link orelse return;
    put(&l.url, span(url));
}

/// 1 for a public address: 4 bytes (IPv4) or 16 bytes (IPv6).
export fn zs_link_address_public(address: ?[*]const u8, len: usize) c_int {
    const a = address orelse return 0;
    return @intFromBool(ol.isPublicAddress(a[0..len]));
}

/// 1 for text that starts with zslice: or web+zslice:.
export fn zs_link_is_link(text: ?[*:0]const u8) c_int {
    return @intFromBool(ol.isLink(span(text)));
}

/// 1 for a name of an STL, 3MF, STEP, STP, or OBJ file.
export fn zs_link_is_model_name(name: ?[*:0]const u8) c_int {
    return @intFromBool(ol.isModelName(span(name)));
}

/// The text for the user of a zs_link_result.
export fn zs_link_message(result: c_int) [*:0]const u8 {
    const r = std.enums.fromInt(Result, result) orelse return "The link did not open.";
    return ol.message(r).ptr;
}

/// The largest download, the most redirects, and the size of struct
/// zs_link, for a shell with no C header (the web app).
export fn zs_link_limits(max_bytes: ?*u64, max_redirects: ?*c_int, link_size: ?*usize) void {
    if (max_bytes) |p| p.* = ol.max_bytes;
    if (max_redirects) |p| p.* = ol.max_redirects;
    if (link_size) |p| p.* = @sizeOf(Link);
}

test "C API: a link, a redirect, and a name" {
    const l = try std.testing.allocator.create(Link);
    defer std.testing.allocator.destroy(l);
    try std.testing.expectEqual(@as(c_int, 0), zs_link_check("zslice://open?file=https%3A%2F%2Fexample.com%2Fdl%2F7", l));
    try std.testing.expectEqualStrings("https://example.com/dl/7", std.mem.sliceTo(&l.url, 0));
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&l.name, 0));
    try std.testing.expectEqual(@as(c_int, 0), zs_link_redirect("/files/part.3mf?t=1", l));
    try std.testing.expectEqualStrings("https://example.com/files/part.3mf?t=1", std.mem.sliceTo(&l.url, 0));
    try std.testing.expectEqual(@as(c_int, 0), zs_link_file_name("", l));
    try std.testing.expectEqualStrings("part.3mf", std.mem.sliceTo(&l.name, 0));
    try std.testing.expectEqual(code(.bad_redirect), zs_link_redirect("https://nas.local/x.stl", l));
    try std.testing.expectEqual(code(.not_public), zs_link_check("zslice://open?file=https://10.1.1.1/a.stl", l));
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&l.url, 0));
    try std.testing.expectEqual(code(.ok), zs_link_check_url("https://example.com/a.obj", l));
    try std.testing.expectEqualStrings("a.obj", std.mem.sliceTo(&l.name, 0));
    try std.testing.expectEqual(@as(c_int, 0), zs_link_address_public(&[_]u8{ 192, 168, 0, 1 }, 4));
    try std.testing.expectEqual(@as(c_int, 1), zs_link_address_public(&[_]u8{ 8, 8, 4, 4 }, 4));
    try std.testing.expectEqualStrings("The file is larger than 512 MB.", std.mem.span(zs_link_message(code(.too_large))));
    try std.testing.expectEqualStrings("The link did not open.", std.mem.span(zs_link_message(99)));
}

test "zs_link_url and zs_link_set_url read and write the URL of the link" {
    var l: Link = undefined;
    zs_link_set_url(&l, "https://example.org/a.stl");
    try std.testing.expectEqualStrings("https://example.org/a.stl", std.mem.span(zs_link_url(&l)));
}
