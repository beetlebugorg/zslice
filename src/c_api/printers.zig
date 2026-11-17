//! The C API of the printer library (src/printers.zig) and of the printer
//! discovery (src/discovery.zig): `include/zslice-app.h`, the sections
//! "Printer library" and "Printer discovery". The rules of the API are in
//! c_api.zig.

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const ok = c.ok;
const gpa = c.gpa;
const Writer = std.Io.Writer;

const printers = zs.printers;
const Library = printers.Library;
const cstr = printers.cstr;
const discovery = zs.discovery;

const invalid = @intFromEnum(Status.invalid_argument);
const out_of_range = @intFromEnum(Status.out_of_range);

// ---- the printer library ----

export fn zs_printers_load(data: ?[*]const u8, len: usize, out: ?*?*Library) c_int {
    const o = out orelse return invalid;
    const d = data orelse return invalid;
    o.* = Library.parse(gpa, d[0..len]) catch |e| return switch (e) {
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        error.InvalidLibrary => @intFromEnum(Status.invalid_value),
    };
    return ok;
}

/// The library in the binary. The wasm module has none: ZS_NOT_SUPPORTED.
export fn zs_printers_builtin(out: ?*?*Library) c_int {
    if (printers.builtin_data.len == 0) return @intFromEnum(Status.not_supported);
    return zs_printers_load(printers.builtin_data.ptr, printers.builtin_data.len, out);
}

export fn zs_printers_free(lib: ?*Library) void {
    if (lib) |l| l.deinit();
}

export fn zs_printers_brand_count(lib: ?*const Library) usize {
    return if (lib) |l| l.brands.len else 0;
}

/// The name of brand i, and its models: first to end (not included).
export fn zs_printers_brand_get(lib: ?*const Library, i: usize, name: ?*[*:0]const u8, first: ?*usize, end: ?*usize) c_int {
    const l = lib orelse return invalid;
    if (i >= l.brands.len) return out_of_range;
    const b = l.brands[i];
    if (name) |n| n.* = cstr(b.name);
    if (first) |f| f.* = b.first;
    if (end) |e| e.* = b.end;
    return ok;
}

export fn zs_printers_model_count(lib: ?*const Library) usize {
    return if (lib) |l| l.models.len else 0;
}

/// zs_printer_model in zslice-app.h.
const CModel = extern struct {
    id: [*:0]const u8,
    brand: [*:0]const u8,
    brand_index: usize,
    name: [*:0]const u8,
    series: [*:0]const u8,
    bed_x: f64,
    bed_y: f64,
    height: f64,
    origin_x: f64,
    origin_y: f64,
    round: bool,
    heated_bed: bool,
    heated_chamber: bool,
    klipper: bool,
    has_start_gcode: bool,
    nozzle: f64,
    nozzles: [*:0]const u8,
    filament: f64,
    max_speed: f64,
    max_accel: f64,
    firmware: [*:0]const u8,
    kinematics: [*:0]const u8,
    extruders: u32,
};

export fn zs_printers_model_get(lib: ?*const Library, i: usize, out: ?*CModel) c_int {
    const l = lib orelse return invalid;
    const o = out orelse return invalid;
    if (i >= l.models.len) return out_of_range;
    const m = l.models[i];
    o.* = .{
        .id = cstr(m.id),
        .brand = cstr(l.brands[m.brand].name),
        .brand_index = m.brand,
        .name = cstr(m.name),
        .series = cstr(m.series),
        .bed_x = m.bed_x,
        .bed_y = m.bed_y,
        .height = m.height,
        .origin_x = m.origin_x,
        .origin_y = m.origin_y,
        .round = m.round,
        .heated_bed = m.heated_bed,
        .heated_chamber = m.heated_chamber,
        .klipper = m.flavor == .klipper,
        .has_start_gcode = m.start != null,
        .nozzle = m.nozzle,
        .nozzles = cstr(m.nozzles),
        .filament = m.filament,
        .max_speed = m.max_speed,
        .max_accel = m.max_accel,
        .firmware = cstr(m.firmware),
        .kinematics = cstr(m.kinematics),
        .extruders = m.extruders,
    };
    return ok;
}

/// The index of the model with this id, or -1.
export fn zs_printers_find(lib: ?*const Library, id: ?[*:0]const u8) isize {
    const l = lib orelse return -1;
    const s = id orelse return -1;
    return if (l.find(std.mem.span(s))) |i| @intCast(i) else -1;
}

/// The models that match `query`, best first. `brand` -1 is all brands.
/// Writes up to `cap` indices to `out`, and returns the count of matches.
export fn zs_printers_search(lib: ?*const Library, query: ?[*:0]const u8, brand: isize, out: ?[*]u32, cap: usize) usize {
    const l = lib orelse return 0;
    const q = if (query) |s| std.mem.span(s) else "";
    var none: [0]u32 = .{};
    const dest: []u32 = if (out) |o| o[0..cap] else &none;
    return l.search(q, if (brand >= 0) @intCast(brand) else null, dest);
}

/// The model that fits a printer on the network, or -1.
export fn zs_printers_match(lib: ?*const Library, hint: ?[*:0]const u8, bed_x: f64, bed_y: f64, height: f64) isize {
    const l = lib orelse return -1;
    const h = if (hint) |s| std.mem.span(s) else "";
    return if (l.match(h, bed_x, bed_y, height)) |i| @intCast(i) else -1;
}

/// Writes `text` to buf (with a 0 at the end, if it fits) and its length to
/// out_len. A buf of NULL asks for the length only.
fn give(text: []const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    if (out_len) |n| n.* = text.len;
    const b = buf orelse return ok;
    if (cap < text.len + 1) return @intFromEnum(Status.write_failed);
    @memcpy(b[0..text.len], text);
    b[text.len] = 0;
    return ok;
}

/// The machine profile of model i, with a nozzle of `nozzle` mm (0: the
/// nozzle of the model).
export fn zs_printers_profile(lib: ?*const Library, i: usize, nozzle: f64, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const l = lib orelse return invalid;
    if (i >= l.models.len) return out_of_range;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    l.profileText(i, nozzle, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return give(aw.written(), buf, cap, out_len);
}

/// The key facts of model i in one line of text, for a list or a card.
export fn zs_printers_facts(lib: ?*const Library, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const l = lib orelse return invalid;
    if (i >= l.models.len) return out_of_range;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    facts(l, i, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return give(aw.written(), buf, cap, out_len);
}

/// The sources of the data of model i, for example "Cura, OrcaSlicer".
export fn zs_printers_sources(lib: ?*const Library, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const l = lib orelse return invalid;
    if (i >= l.models.len) return out_of_range;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    l.sourceNames(l.models[i], &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return give(aw.written(), buf, cap, out_len);
}

/// "220 × 220 × 250 mm · heated bed · Klipper · CoreXY".
pub fn facts(l: *const Library, i: usize, w: *Writer) Writer.Error!void {
    const m = l.models[i];
    if (m.round) try w.print("⌀ {d} × {d} mm", .{ m.bed_x, m.height }) else try w.print("{d} × {d} × {d} mm", .{ m.bed_x, m.bed_y, m.height });
    if (m.heated_chamber) try w.writeAll(" · heated chamber") else if (m.heated_bed) try w.writeAll(" · heated bed");
    if (m.firmware.len > 0) try w.print(" · {s}", .{m.firmware});
    const kin = m.kinematics;
    if (std.ascii.eqlIgnoreCase(kin, "corexy")) try w.writeAll(" · CoreXY") else if (std.ascii.eqlIgnoreCase(kin, "delta")) try w.writeAll(" · delta") else if (std.ascii.eqlIgnoreCase(kin, "hbot")) try w.writeAll(" · H-bot");
    if (m.extruders > 1) try w.print(" · {d} extruders", .{m.extruders});
}

// ---- printer discovery ----

const Finder = discovery.Finder;

export fn zs_discovery_new(out: ?*?*Finder) c_int {
    const o = out orelse return invalid;
    const f = gpa.create(Finder) catch return @intFromEnum(Status.out_of_memory);
    f.* = Finder.init(gpa);
    o.* = f;
    return ok;
}

export fn zs_discovery_free(finder: ?*Finder) void {
    const f = finder orelse return;
    f.deinit();
    gpa.destroy(f);
}

/// The query packet, for 224.0.0.251 port 5353. It stays valid until the
/// next call.
export fn zs_discovery_query(finder: ?*Finder, out: ?*[*]const u8, len: ?*usize) c_int {
    const f = finder orelse return invalid;
    const q = f.query();
    if (out) |o| o.* = q.ptr;
    if (len) |n| n.* = q.len;
    return ok;
}

/// Reads a packet. Returns 1 if the list changed or the next query has new
/// questions, 0 if not, or -1 on an error.
export fn zs_discovery_feed(finder: ?*Finder, data: ?[*]const u8, len: usize) c_int {
    const f = finder orelse return -1;
    const d = data orelse return -1;
    const changed = f.feed(d[0..len]) catch return -1;
    return @intFromBool(changed);
}

export fn zs_discovery_count(finder: ?*const Finder) usize {
    return if (finder) |f| f.found.items.len else 0;
}

/// zs_found_printer in zslice-app.h.
const CFound = extern struct {
    name: [*:0]const u8,
    kind: c_int,
    kind_title: [*:0]const u8,
    host: [*:0]const u8,
    address: [*:0]const u8,
    port: c_int,
    url: [*:0]const u8,
    model: [*:0]const u8,
    version: [*:0]const u8,
    bed_x: f64,
    bed_y: f64,
    height: f64,
    origin_x: f64,
    origin_y: f64,
};

export fn zs_discovery_get(finder: ?*const Finder, i: usize, out: ?*CFound) c_int {
    const f = finder orelse return invalid;
    const o = out orelse return invalid;
    if (i >= f.found.items.len) return out_of_range;
    const p = f.found.items[i];
    const title: [:0]const u8 = switch (p.kind) {
        inline else => |k| comptime titleZ(k),
    };
    o.* = .{
        .name = p.name.ptr,
        .kind = @intFromEnum(p.kind),
        .kind_title = title.ptr,
        .host = p.host.ptr,
        .address = p.address.ptr,
        .port = p.port,
        .url = p.url.ptr,
        .model = p.model.ptr,
        .version = p.version.ptr,
        .bed_x = p.bed_x,
        .bed_y = p.bed_y,
        .height = p.height,
        .origin_x = p.origin_x,
        .origin_y = p.origin_y,
    };
    return ok;
}

fn titleZ(comptime k: discovery.Kind) [:0]const u8 {
    return k.title() ++ "";
}

/// Reads the answer of printer i to a request (ZS_FOUND_REPLY_*). Returns
/// 1 if the entry changed, 0 if not, or -1 on an error.
export fn zs_discovery_reply(finder: ?*Finder, i: usize, what: c_int, body: ?[*]const u8, len: usize) c_int {
    const f = finder orelse return -1;
    const b = body orelse return -1;
    const r = std.enums.fromInt(discovery.Reply, what) orelse return -1;
    const changed = f.reply(i, r, b[0..len]) catch return -1;
    return @intFromBool(changed);
}

test "the C API of the library" {
    const data = "zslice-printers 1\nS\tc\tCura\tLGPL-3.0-or-later\thttps://github.com/Ultimaker/Cura\t\nB\tAcme\nP\tacme-one\tOne\tOne\tc\t200\t210\t220\t0\t0\t\t0.4\t\t1.75\tb\t300\t1500\t10\t8\tmarlin\tMarlin\tcorexy\t1\t40\t\t\t1\n";
    var lib: ?*Library = null;
    try std.testing.expectEqual(ok, zs_printers_load(data.ptr, data.len, &lib));
    defer zs_printers_free(lib);
    try std.testing.expectEqual(@as(usize, 1), zs_printers_brand_count(lib));
    var m: CModel = undefined;
    try std.testing.expectEqual(ok, zs_printers_model_get(lib, 0, &m));
    try std.testing.expectEqualStrings("Acme", std.mem.span(m.brand));
    try std.testing.expectEqualStrings("One", std.mem.span(m.name));
    try std.testing.expect(!m.has_start_gcode);
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    try std.testing.expectEqual(ok, zs_printers_facts(lib, 0, &buf, buf.len, &n));
    try std.testing.expectEqualStrings("200 × 210 × 220 mm · heated bed · Marlin · CoreXY", buf[0..n]);
    try std.testing.expectEqual(ok, zs_printers_profile(lib, 0, 0.6, null, 0, &n));
    try std.testing.expect(n > 50);
    var idx: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), zs_printers_search(lib, "acme o", -1, &idx, idx.len));
    try std.testing.expectEqual(@as(isize, 0), zs_printers_find(lib, "acme-one"));
    try std.testing.expectEqual(@as(isize, 0), zs_printers_match(lib, "Acme One", 0, 0, 0));
    try std.testing.expectEqual(@intFromEnum(Status.invalid_value), zs_printers_load("x".ptr, 1, &lib));
    // The sizes of the structs of zslice-app.h on a 64-bit target (gcc).
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 152), @sizeOf(CModel));
        try std.testing.expectEqual(@as(usize, 112), @sizeOf(CFound));
    }
}

test "the C API of the discovery" {
    var f: ?*Finder = null;
    try std.testing.expectEqual(ok, zs_discovery_new(&f));
    defer zs_discovery_free(f);
    var q: [*]const u8 = undefined;
    var n: usize = 0;
    try std.testing.expectEqual(ok, zs_discovery_query(f, &q, &n));
    try std.testing.expect(n > 12);
    try std.testing.expectEqual(@as(c_int, 0), zs_discovery_feed(f, q, n));
    try std.testing.expectEqual(@as(usize, 0), zs_discovery_count(f));
    try std.testing.expectEqual(@as(c_int, -1), zs_discovery_reply(f, 0, 9, "x", 1));
}
