//! Links that open a model: `zslice://open?file=<percent-encoded https URL>`.
//!
//! Model sites have "Open in slicer" buttons with links of this form. The
//! shape comes from the `prusaslicer://open?file=` links (see
//! docs/references/prusaslicer.md). The rules here are the rules of all
//! zslice apps, so that each app accepts and refuses the same links. The
//! contract is in docs/internals/open-links.md.
//!
//! Any web page can start such a link, so the rules are strict:
//!
//! - The file comes over https from a public host name. An IP address, a
//!   local name (`.local`, `.lan`, `localhost`, and others), a user name in
//!   the URL, and a port other than 443 are refused. The last label of the
//!   host must be letters (or `xn--`), so no form of an IP address passes.
//! - Each redirect passes the same check.
//! - The shell checks each address that the name resolves to, and the
//!   address of the connection (`isPublicAddress`), where the platform
//!   lets it. A name of a public site can still resolve to a device on the
//!   local network.
//! - The file is an STL, 3MF, STEP, STP, or OBJ file of at most
//!   `max_bytes`. A zslice project is refused (the shell checks the bytes
//!   with zs_project_file_is).
//! - The shell asks the user before the download, and a link never starts
//!   a print.
//!
//! The web app also takes `web+zslice://open?file=` (a page can register
//! only a scheme that starts with `web+`) and a plain https URL in
//! `?open=`.
//!
//! This module does no I/O and allocates nothing: each function writes
//! into buffers of the caller.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

/// The largest file that a link can download: 512 MB.
pub const max_bytes: u64 = 512 << 20;
/// The most redirects of one download.
pub const max_redirects = 5;
/// The longest link and the longest URL in it.
pub const max_link = 4096;
/// The size of a buffer for a checked URL, with its NUL byte: each byte of
/// the path can grow to three (%XX).
pub const url_cap = 3 * max_link + 16;
/// The size of a buffer for a host name, with its NUL byte.
pub const host_cap = 256;
/// The size of a buffer for a file name, with its NUL byte.
pub const name_cap = 512;
/// The most characters of a file name.
const name_chars = 120;

/// The result of a check. The numbers are the C API (enum zs_link_result).
pub const Result = enum(c_int) {
    ok = 0,
    not_a_link = 1,
    not_public = 2,
    local_address = 3,
    not_a_model = 4,
    project = 5,
    too_large = 6,
    web_page = 7,
    too_many_redirects = 8,
    bad_redirect = 9,
};

/// The text for the user of each result.
pub fn message(r: Result) [:0]const u8 {
    return switch (r) {
        .ok => "",
        .not_a_link => "The link is not valid.",
        .not_public => "The link does not lead to a public https address.",
        .local_address => "The link leads to a device on a local network.",
        .not_a_model => "The link does not lead to an STL, 3MF, STEP, or OBJ file.",
        .project => "A link does not open a zslice project. Save the file, then open it.",
        .too_large => "The file is larger than 512 MB.",
        .web_page => "The link leads to a web page, not to a model file.",
        .too_many_redirects => "The site sent too many redirects.",
        .bad_redirect => "The site sent the download to an address that zslice does not trust.",
    };
}

/// A checked URL: slices of the buffers of the caller.
pub const Url = struct {
    url: []const u8,
    host: []const u8,
};

/// A checked link: the URL, its host, and the file name in the URL (empty
/// if the URL has no model file name).
pub const Link = struct {
    url: []const u8,
    host: []const u8,
    name: []const u8,
};

/// A link that passes, or the reason of a refusal.
pub const Checked = union(enum) { ok: Link, refused: Result };

/// Buffers for one check.
pub const Buffers = struct {
    url: [url_cap]u8 = undefined,
    host: [host_cap]u8 = undefined,
    name: [name_cap]u8 = undefined,
    scratch: [max_link]u8 = undefined,
};

fn startsWithIgnoreCase(text: []const u8, head: []const u8) bool {
    return text.len >= head.len and std.ascii.eqlIgnoreCase(text[0..head.len], head);
}

fn endsWith(text: []const u8, tail: []const u8) bool {
    return std.mem.endsWith(u8, text, tail);
}

/// True for text that starts with a scheme of a link: `zslice:` or
/// `web+zslice:`.
pub fn isLink(text: []const u8) bool {
    return startsWithIgnoreCase(text, "zslice:") or startsWithIgnoreCase(text, "web+zslice:");
}

/// True for a name that ends in .stl, .3mf, .step, .stp, or .obj, with a
/// name before the dot.
pub fn isModelName(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    const before = name[dot - 1];
    if (before == '/' or before == '\\') return false;
    const ext = name[dot..];
    for ([_][]const u8{ ".stl", ".3mf", ".step", ".stp", ".obj" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decodes %XX into out. Null for a bad escape or a full buffer.
fn percentDecode(text: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (n >= out.len) return null;
        if (text[i] != '%') {
            out[n] = text[i];
            n += 1;
            continue;
        }
        if (i + 2 >= text.len) return null;
        const hi = hexDigit(text[i + 1]) orelse return null;
        const lo = hexDigit(text[i + 2]) orelse return null;
        out[n] = hi * 16 + lo;
        n += 1;
        i += 2;
    }
    return out[0..n];
}

/// A host name of a local network or of this computer.
fn localHostName(host: []const u8) bool {
    for ([_][]const u8{ ".local", ".localhost", ".internal", ".lan", ".home", ".arpa", ".localdomain", ".intranet", ".corp", ".private" }) |tail| {
        if (endsWith(host, tail)) return true;
    }
    return false;
}

/// Checks an https URL and writes its clean form: the host in lowercase,
/// no port, no fragment, and %XX for each byte over 0x7F and each space.
/// Null if the URL is not a public https URL.
pub fn checkUrl(text: []const u8, url_buf: []u8, host_buf: []u8) ?Url {
    if (text.len > max_link or !startsWithIgnoreCase(text, "https://")) return null;
    var rest = text[8..];
    for (rest) |c| {
        if (c < 0x20 or c == 0x7F or c == '\\' or c == '"' or c == '<' or c == '>') return null;
    }
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| rest = rest[0..hash];
    const end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    var authority = rest[0..end];
    const tail = rest[end..];
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return null;
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        if (!std.mem.eql(u8, authority[colon + 1 ..], "443")) return null;
        authority = authority[0..colon];
    }
    if (authority.len < 4 or authority.len > 253 or authority.len >= host_buf.len) return null;
    const host = host_buf[0..authority.len];
    for (authority, 0..) |c, i| host[i] = std.ascii.toLower(c);
    if (host[0] == '.' or host[0] == '-' or host[host.len - 1] == '.' or host[host.len - 1] == '-') return null;
    if (std.mem.indexOf(u8, host, "..") != null) return null;
    for (host) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '-')) return null;
    }
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return null;
    if (localHostName(host)) return null;
    const label = host[dot + 1 ..];
    if (label.len < 2) return null;
    if (!std.mem.startsWith(u8, label, "xn--")) {
        for (label) |c| if (c < 'a' or c > 'z') return null;
    }
    host_buf[host.len] = 0;

    var n: usize = 0;
    const put = struct {
        fn f(buf: []u8, at: *usize, bytes: []const u8) bool {
            if (at.* + bytes.len >= buf.len) return false;
            @memcpy(buf[at.* .. at.* + bytes.len], bytes);
            at.* += bytes.len;
            return true;
        }
    }.f;
    if (!put(url_buf, &n, "https://")) return null;
    if (!put(url_buf, &n, host)) return null;
    if (tail.len == 0 or tail[0] == '?') {
        if (!put(url_buf, &n, "/")) return null;
    }
    const hex = "0123456789ABCDEF";
    for (tail) |c| {
        if (c < 0x80 and c != ' ') {
            if (!put(url_buf, &n, &.{c})) return null;
        } else {
            if (!put(url_buf, &n, &.{ '%', hex[c >> 4], hex[c & 15] })) return null;
        }
    }
    url_buf[n] = 0;
    return .{ .url = url_buf[0..n], .host = host_buf[0..host.len] };
}

/// True for a code point that changes the direction of the text. Such a
/// mark can hide the real extension of a name ("a<RLO>lts.exe").
fn directionMark(cp: u21) bool {
    return cp == 0x061C or cp == 0x200E or cp == 0x200F or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069);
}

/// A file name to show and to keep: no folder, no control character, no
/// direction mark, none of <>:"|?*, no space or dot at the end, and at
/// most 120 characters (the extension stays). Empty for text that is not
/// UTF-8.
pub fn cleanName(raw: []const u8, out: []u8) []const u8 {
    var base = raw;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |at| base = base[at + 1 ..];
    const view = std.unicode.Utf8View.init(base) catch return out[0..0];
    var it = view.iterator();
    var n: usize = 0;
    // The byte offset in out of each of the first characters, for the cut
    // below.
    var starts: [name_chars + 1]usize = undefined;
    var count: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return out[0..0];
        if (cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp < 0xA0) or directionMark(cp)) continue;
        if (cp < 0x80 and std.mem.indexOfScalar(u8, "<>:\"|?*", @intCast(cp)) != null) continue;
        if (n + slice.len + 1 > out.len) break;
        if (count < starts.len) starts[count] = n;
        @memcpy(out[n .. n + slice.len], slice);
        n += slice.len;
        count += 1;
    }
    while (n > 0 and (out[n - 1] == ' ' or out[n - 1] == '.')) {
        n -= 1;
        // A trailing space or dot is one byte and one character.
        count -= 1;
    }
    if (count > name_chars) {
        // Keep the extension (a dot and at most 7 bytes) after 120 - its
        // length characters.
        const name = out[0..n];
        var ext_len: usize = 0;
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            if (n - dot <= 8) ext_len = n - dot;
        }
        var ext: [8]u8 = undefined;
        @memcpy(ext[0..ext_len], name[n - ext_len ..]);
        const at = starts[name_chars - ext_len];
        @memcpy(out[at .. at + ext_len], ext[0..ext_len]);
        n = at + ext_len;
    }
    if (n < out.len) out[n] = 0;
    return out[0..n];
}

/// The last part of the path of a checked URL, decoded and clean.
pub fn nameInUrl(url: []const u8, scratch: []u8, out: []u8) []const u8 {
    if (url.len < 8) return out[0..0];
    const start = std.mem.indexOfScalarPos(u8, url, 8, '/') orelse return out[0..0];
    const end = std.mem.indexOfScalarPos(u8, url, start, '?') orelse url.len;
    const path = url[start..end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const decoded = percentDecode(path[slash + 1 ..], scratch) orelse return out[0..0];
    return cleanName(decoded, out);
}

/// The file name of a Content-Disposition header: `filename*=UTF-8''...`
/// first, then `filename=`.
pub fn nameInDisposition(header: []const u8, scratch: []u8, out: []u8) []const u8 {
    if (indexOfIgnoreCase(header, "filename*=")) |at| {
        const value_end = std.mem.indexOfScalarPos(u8, header, at, ';') orelse header.len;
        const value = header[at + 10 .. value_end];
        if (std.mem.indexOf(u8, value, "''")) |mark| {
            if (percentDecode(std.mem.trim(u8, value[mark + 2 ..], " \""), scratch)) |decoded| {
                const name = cleanName(decoded, out);
                if (name.len > 0) return name;
            }
        }
    }
    var from: usize = 0;
    while (indexOfIgnoreCasePos(header, from, "filename=")) |at| {
        from = at + 9;
        // Skip the "filename=" inside "filename*=".
        if (at > 0 and header[at - 1] == '*') continue;
        var value = header[at + 9 ..];
        if (value.len > 0 and value[0] == '"') {
            value = value[1..];
            value = value[0 .. std.mem.indexOfScalar(u8, value, '"') orelse value.len];
        } else {
            value = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " ");
        }
        return cleanName(value, out);
    }
    return out[0..0];
}

fn indexOfIgnoreCase(text: []const u8, needle: []const u8) ?usize {
    return indexOfIgnoreCasePos(text, 0, needle);
}

fn indexOfIgnoreCasePos(text: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len > text.len) return null;
    var i = from;
    while (i + needle.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Reads a link: `zslice://open?file=<URL>` (also `zslice://open/?`, and
/// `web+zslice:` in place of `zslice:`). The query has one `file`. Other
/// keys are skipped.
pub fn parse(text: []const u8, b: *Buffers) Checked {
    if (text.len > max_link) return .{ .refused = .not_a_link };
    var rest: []const u8 = undefined;
    const forms = [_][]const u8{ "zslice://open?", "zslice://open/?", "web+zslice://open?", "web+zslice://open/?" };
    for (forms) |head| {
        if (startsWithIgnoreCase(text, head)) {
            rest = text[head.len..];
            break;
        }
    } else return .{ .refused = .not_a_link };
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| rest = rest[0..hash];
    var file: []const u8 = "";
    var found: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "file=")) {
            found += 1;
            file = pair[5..];
        }
    }
    if (found != 1) return .{ .refused = .not_a_link };
    const decoded = percentDecode(file, &b.scratch) orelse return .{ .refused = .not_a_link };
    return checkModelUrl(decoded, b);
}

/// Checks a plain https URL (the web app takes one in `?open=`).
pub fn checkModelUrl(text: []const u8, b: *Buffers) Checked {
    // The decoded URL can sit in b.scratch, so copy it first: nameInUrl
    // uses the scratch buffer.
    var copy: [max_link]u8 = undefined;
    if (text.len > copy.len) return .{ .refused = .not_public };
    @memcpy(copy[0..text.len], text);
    const u = checkUrl(copy[0..text.len], &b.url, &b.host) orelse return .{ .refused = .not_public };
    var name = nameInUrl(u.url, &b.scratch, &b.name);
    if (!isModelName(name)) name = b.name[0..0];
    b.name[name.len] = 0;
    return .{ .ok = .{ .url = u.url, .host = u.host, .name = name } };
}

/// The next URL of a redirect from `from` (a checked URL): an absolute
/// `Location`, or a path on the same host. Null if the next URL fails the
/// check.
pub fn redirect(location: []const u8, from: []const u8, b: *Buffers) ?Url {
    var joined: [max_link]u8 = undefined;
    var next = std.mem.trim(u8, location, " \t");
    if (next.len > 0 and next[0] == '/' and !(next.len > 1 and next[1] == '/')) {
        // A path on the same host: https://<host> of `from`.
        const host_end = std.mem.indexOfScalarPos(u8, from, 8, '/') orelse from.len;
        if (host_end + next.len > joined.len) return null;
        @memcpy(joined[0..host_end], from[0..host_end]);
        @memcpy(joined[host_end .. host_end + next.len], next);
        next = joined[0 .. host_end + next.len];
    }
    return checkUrl(next, &b.url, &b.host);
}

/// The name of the downloaded file: from the Content-Disposition header,
/// else from the last URL, else from the link. Empty if none of them is a
/// model name.
pub fn fileName(disposition: []const u8, url: []const u8, link_name: []const u8, b: *Buffers) []const u8 {
    var name = nameInDisposition(disposition, &b.scratch, &b.name);
    if (isModelName(name)) return name;
    name = nameInUrl(url, &b.scratch, &b.name);
    if (isModelName(name)) return name;
    var copy: [name_cap]u8 = undefined;
    const n = @min(link_name.len, copy.len);
    @memcpy(copy[0..n], link_name[0..n]);
    name = cleanName(copy[0..n], &b.name);
    if (isModelName(name)) return name;
    b.name[0] = 0;
    return b.name[0..0];
}

/// Checks the head of an answer: a web page and a length over the limit are
/// refused. `length` is -1 when the answer has none.
pub fn checkReply(content_type: []const u8, length: i64) Result {
    if (startsWithIgnoreCase(std.mem.trim(u8, content_type, " "), "text/html")) return .web_page;
    if (length > 0 and @as(u64, @intCast(length)) > max_bytes) return .too_large;
    return .ok;
}

/// False for an address that is not on the public internet: loopback,
/// private, shared (100.64/10), link-local, multicast, reserved,
/// benchmark, unique local, site-local, and the IPv6 forms of these
/// (mapped, NAT64, 6to4). `bytes` is 4 (IPv4) or 16 (IPv6) bytes in
/// network order.
pub fn isPublicAddress(bytes: []const u8) bool {
    if (bytes.len == 4) return publicV4(bytes[0..4].*);
    if (bytes.len != 16) return false;
    const b = bytes;
    const zero10 = std.mem.allEqual(u8, b[0..10], 0);
    // ::ffff:a.b.c.d and the old ::a.b.c.d.
    if (zero10 and b[10] == 0xFF and b[11] == 0xFF) return publicV4(b[12..16].*);
    if (zero10 and b[10] == 0 and b[11] == 0) {
        if (std.mem.allEqual(u8, b[12..15], 0) and b[15] <= 1) return false; // :: and ::1
        return publicV4(b[12..16].*);
    }
    // NAT64 (64:ff9b::/96) and 6to4 (2002::/16) carry an IPv4 address.
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xFF and b[3] == 0x9B and std.mem.allEqual(u8, b[4..12], 0)) return publicV4(b[12..16].*);
    if (b[0] == 0x20 and b[1] == 0x02) return publicV4(b[2..6].*);
    if ((b[0] & 0xFE) == 0xFC) return false; // unique local
    if (b[0] == 0xFF) return false; // multicast
    if (b[0] == 0xFE and (b[1] & 0xC0) == 0x80) return false; // link-local
    if (b[0] == 0xFE and (b[1] & 0xC0) == 0xC0) return false; // site-local
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0D and b[3] == 0xB8) return false; // documentation
    return true;
}

fn publicV4(b: [4]u8) bool {
    if (b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224) return false;
    if (b[0] == 100 and (b[1] & 0xC0) == 64) return false;
    if (b[0] == 169 and b[1] == 254) return false;
    if (b[0] == 172 and (b[1] & 0xF0) == 16) return false;
    if (b[0] == 192 and (b[1] == 168 or (b[1] == 0 and b[2] == 0))) return false;
    if (b[0] == 198 and (b[1] == 18 or b[1] == 19)) return false;
    return true;
}

// ---- tests ----

const testing = std.testing;

fn parsed(text: []const u8, b: *Buffers) ?Link {
    return switch (parse(text, b)) {
        .ok => |l| l,
        .refused => null,
    };
}

test "a link of a model site" {
    var b: Buffers = .{};
    const l = parsed("zslice://open?file=https%3A%2F%2Ffiles.printables.com%2Fmedia%2Fa%20b.stl", &b).?;
    try testing.expectEqualStrings("files.printables.com", l.host);
    try testing.expectEqualStrings("https://files.printables.com/media/a%20b.stl", l.url);
    try testing.expectEqualStrings("a b.stl", l.name);
    // The NUL bytes for the C API.
    try testing.expectEqual(@as(u8, 0), b.url[l.url.len]);
    try testing.expectEqual(@as(u8, 0), b.host[l.host.len]);
    try testing.expectEqual(@as(u8, 0), b.name[l.name.len]);
}

test "the forms of a link" {
    var b: Buffers = .{};
    var l = parsed("ZSLICE://open/?x=1&file=https://Example.com:443/m.3mf?v=2#top", &b).?;
    try testing.expectEqualStrings("https://example.com/m.3mf?v=2", l.url);
    try testing.expectEqualStrings("m.3mf", l.name);
    l = parsed("zslice://open?file=https://example.com/download/42", &b).?;
    try testing.expectEqualStrings("", l.name);
    l = parsed("web+zslice://open?file=https%3A%2F%2Fexample.com%2Fa.step", &b).?;
    try testing.expectEqualStrings("a.step", l.name);
    l = parsed("zslice://open?file=https://example.com?x=1", &b).?;
    try testing.expectEqualStrings("https://example.com/?x=1", l.url);
    l = parsed("zslice://open?file=https://xn--bcher-kva.example/%C3%BC.obj", &b).?;
    try testing.expectEqualStrings("\xC3\xBC.obj", l.name);
    // A byte over 0x7F goes out as %XX.
    l = parsed("zslice://open?file=https%3A%2F%2Fexample.com%2F%C3%BC%20x.stl", &b).?;
    try testing.expectEqualStrings("https://example.com/%C3%BC%20x.stl", l.url);
    try testing.expectEqualStrings("\xC3\xBC x.stl", l.name);
}

test "refused links" {
    var b: Buffers = .{};
    const refused = [_][]const u8{
        "zslice://open?file=http://example.com/a.stl",
        "zslice://open?file=file:///C:/secret.stl",
        "zslice://open?file=https://127.0.0.1/a.stl",
        "zslice://open?file=https://2130706433/a.stl",
        "zslice://open?file=https://0x7f.0.0.1/a.stl",
        "zslice://open?file=https://[::1]/a.stl",
        "zslice://open?file=https://localhost/a.stl",
        "zslice://open?file=https://printer.local/a.stl",
        "zslice://open?file=https://printer.LAN/a.stl",
        "zslice://open?file=https://router.home.arpa/a.stl",
        "zslice://open?file=https://user:pw@example.com/a.stl",
        "zslice://open?file=https://example.com:8080/a.stl",
        "zslice://open?file=https://example.com%5C@evil.test/a.stl",
        "zslice://open?file=https://a.test/a.stl&file=https://b.test/b.stl",
        "zslice://open?file=https%3A%2F%2Fexample.com%2",
        "zslice://print?file=https://example.com/a.stl",
        "zslice://open",
        "zslice://open?url=https://example.com/a.stl",
        "https://example.com/a.stl",
        "zslice://open?file=https://.example.com/a.stl",
        "zslice://open?file=https://example..com/a.stl",
        "zslice://open?file=https://example.c/a.stl",
        "zslice://open?file=https://example.com%0A.evil/a.stl",
        "zslice://open?file=https://ex_ample.com/a.stl",
        "zslice://open?file=https://example.com/a\"b.stl",
    };
    for (refused) |text| {
        if (parsed(text, &b) != null) {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
    var long: [max_link + 10]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..19], "zslice://open?file=");
    try testing.expect(parsed(&long, &b) == null);
}

test "the result of a refused link" {
    var b: Buffers = .{};
    try testing.expectEqual(Result.not_a_link, parse("zslice://x", &b).refused);
    try testing.expectEqual(Result.not_public, parse("zslice://open?file=https://10.0.0.1/a.stl", &b).refused);
    try testing.expectEqualStrings("The link is not valid.", message(.not_a_link));
}

test "a name cannot hide its extension" {
    var b: Buffers = .{};
    const l = parsed("zslice://open?file=https://example.com/a%E2%80%AEexe.stl", &b).?;
    try testing.expectEqualStrings("aexe.stl", l.name);
    // A folder in an encoded slash, and control characters (encoded twice:
    // the link decodes once, the name once more).
    const m = parsed("zslice://open?file=https://example.com/x%252F..%252F..%255Cevil%250D.stl", &b).?;
    try testing.expectEqualStrings("evil.stl", m.name);
    // Not UTF-8: no name.
    const n = parsed("zslice://open?file=https://example.com/%FF.stl", &b).?;
    try testing.expectEqualStrings("", n.name);
}

test "a long name keeps its extension" {
    var out: [name_cap]u8 = undefined;
    const long = "a" ** 300 ++ ".step";
    const name = cleanName(long, &out);
    try testing.expectEqual(@as(usize, name_chars), name.len);
    try testing.expect(std.mem.endsWith(u8, name, "a.step"));
    // Multi-byte characters count as one each.
    const wide = "\xC3\xBC" ** 200 ++ ".stl";
    const w = cleanName(wide, &out);
    try testing.expect(std.mem.endsWith(u8, w, ".stl"));
    try testing.expect(std.unicode.utf8ValidateSlice(w));
    try testing.expectEqual(@as(usize, name_chars), try std.unicode.utf8CountCodepoints(w));
    try testing.expectEqualStrings("x.stl", cleanName("x.stl. . ", &out));
}

test "model names" {
    for ([_][]const u8{ "C:\\x\\Part.STL", "a.step", "a.stp", "a.obj", "a.3mf" }) |n| try testing.expect(isModelName(n));
    for ([_][]const u8{ "a.exe", "stl", ".stl", "x/.stl", "a.stl.exe", "a.gcode" }) |n| try testing.expect(!isModelName(n));
}

test "the name of a download" {
    var b: Buffers = .{};
    try testing.expectEqualStrings("Part 1.3mf", fileName("attachment; filename*=UTF-8''Part%201.3mf; filename=\"x.stl\"", "https://e.com/dl/1", "", &b));
    try testing.expectEqualStrings("x.stl", fileName("attachment; filename=\"x.stl\"", "https://e.com/dl/1", "", &b));
    try testing.expectEqualStrings("y.obj", fileName("attachment; filename=y.obj; size=3", "https://e.com/dl/1", "", &b));
    try testing.expectEqualStrings("z.stl", fileName("", "https://e.com/files/z.stl?sig=1", "", &b));
    try testing.expectEqualStrings("w.stp", fileName("inline", "https://e.com/dl/1", "w.stp", &b));
    try testing.expectEqualStrings("", fileName("attachment; filename=\"a.exe\"", "https://e.com/a.zip", "", &b));
    try testing.expectEqualStrings("e.stl", fileName("attachment; filename=\"..\\..\\e.stl\"", "https://e.com/x", "", &b));
}

test "a redirect" {
    var b: Buffers = .{};
    var r = redirect("/files/b.stl", "https://example.com/a/a.stl", &b).?;
    try testing.expectEqualStrings("https://example.com/files/b.stl", r.url);
    r = redirect("https://cdn.example.net/x.stl", "https://example.com/a.stl", &b).?;
    try testing.expectEqualStrings("cdn.example.net", r.host);
    try testing.expect(redirect("http://cdn.example.net/x.stl", "https://example.com/a.stl", &b) == null);
    try testing.expect(redirect("https://192.168.1.2/x.stl", "https://example.com/a.stl", &b) == null);
    try testing.expect(redirect("//printer.local/x.stl", "https://example.com/a.stl", &b) == null);
    try testing.expect(redirect("x.stl", "https://example.com/a.stl", &b) == null);
}

test "the head of an answer" {
    try testing.expectEqual(Result.web_page, checkReply("text/html; charset=utf-8", 10));
    try testing.expectEqual(Result.too_large, checkReply("model/stl", 600 << 20));
    try testing.expectEqual(Result.ok, checkReply("application/octet-stream", -1));
    try testing.expectEqual(Result.ok, checkReply("", 512 << 20));
}

test "public addresses" {
    const v4 = struct {
        fn f(a: u8, b: u8, c: u8, d: u8) bool {
            return isPublicAddress(&.{ a, b, c, d });
        }
    }.f;
    try testing.expect(v4(93, 184, 216, 34));
    try testing.expect(v4(8, 8, 8, 8));
    try testing.expect(!v4(127, 0, 0, 1));
    try testing.expect(!v4(10, 1, 2, 3));
    try testing.expect(!v4(172, 16, 0, 1));
    try testing.expect(!v4(172, 31, 9, 9));
    try testing.expect(v4(172, 32, 0, 1));
    try testing.expect(!v4(192, 168, 1, 5));
    try testing.expect(!v4(169, 254, 1, 1));
    try testing.expect(!v4(100, 64, 0, 1));
    try testing.expect(!v4(0, 0, 0, 0));
    try testing.expect(!v4(224, 0, 0, 1));
    try testing.expect(!v4(255, 255, 255, 255));

    const v6 = struct {
        fn f(text: []const u8) bool {
            const a = std.Io.net.Ip6Address.parse(text, 0) catch unreachable;
            return isPublicAddress(&a.bytes);
        }
    }.f;
    try testing.expect(v6("2606:4700::1111"));
    for ([_][]const u8{ "::1", "::", "fe80::1", "fc00::1", "fd12::1", "ff02::1", "::ffff:192.168.1.5", "::ffff:127.0.0.1", "64:ff9b::a00:1", "2002:c0a8:105::1", "fec0::1", "2001:db8::1" }) |t| {
        if (v6(t)) {
            std.debug.print("public: {s}\n", .{t});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(v6("::ffff:8.8.8.8"));
    try testing.expect(!isPublicAddress(&.{ 1, 2, 3 }));
}
