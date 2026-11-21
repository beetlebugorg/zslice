//! Fuzz tests of the readers of outside files and network packets.
//!
//! Each test takes some valid inputs (the seeds), changes them at random
//! many times, and gives each result to a reader. A reader must return a
//! value or an error. It must not panic, read out of bounds, leak memory,
//! or ask for more memory than a limit. The changes: a byte flips, a range
//! goes away or comes twice, a 32-bit number becomes a large one, and the
//! input gets cut. Some crafted inputs test deep nesting.
//!
//! `zig build test` runs a few hundred rounds with a fixed seed. Set
//! ZSLICE_FUZZ_ROUNDS to run more rounds, and ZSLICE_FUZZ_SEED to start
//! from another seed:
//!
//!   ZSLICE_FUZZ_ROUNDS=200000 zig build test -Dtest-filter=fuzz
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const zipfile = @import("zipfile.zig");
const threemf = @import("threemf.zig");
const Mesh = @import("mesh.zig").Mesh;
const yaml = @import("yaml.zig");
const project = @import("project.zig");
const toml = @import("toml.zig");
const expr = @import("expr.zig");
const gcode_read = @import("gcode_read.zig");
const gcode_vars = @import("gcode_vars.zig");
const mqtt = @import("mqtt.zig");
const bambu = @import("bambu.zig");
const discovery = @import("discovery.zig");
const import_cura = @import("import_cura.zig");
const settings_mod = @import("settings.zig");
const font = @import("font.zig");

/// The most memory that one input can ask for. A small file that asks
/// for more is a zip bomb or a size field that lies.
const memory_limit = 256 << 20;

fn env(name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    return testing.environ.getPosix(name);
}

fn rounds(default: usize) usize {
    const t = env("ZSLICE_FUZZ_ROUNDS") orelse return default;
    return std.fmt.parseInt(usize, t, 10) catch default;
}

fn seed() u64 {
    const t = env("ZSLICE_FUZZ_SEED") orelse return 0x5eed;
    return std.fmt.parseInt(u64, t, 10) catch 0x5eed;
}

/// An allocator that fails when the live memory goes over a limit. It
/// sits on top of the testing allocator, which finds leaks.
const Limited = struct {
    parent: Allocator,
    live: usize = 0,
    limit: usize,

    fn allocator(self: *Limited) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (len > self.limit - self.live) return null;
        const p = self.parent.rawAlloc(len, a, ra) orelse return null;
        self.live += len;
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (new_len > m.len and new_len - m.len > self.limit - self.live) return false;
        if (!self.parent.rawResize(m, a, new_len, ra)) return false;
        self.live = self.live - m.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (new_len > m.len and new_len - m.len > self.limit - self.live) return null;
        const p = self.parent.rawRemap(m, a, new_len, ra) orelse return null;
        self.live = self.live - m.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(m, a, ra);
        self.live -= m.len;
    }
};

/// Changes `in` at random, into `out`. Returns the new bytes.
fn mutate(rand: std.Random, in: []const u8, out: *std.ArrayList(u8), gpa: Allocator) ![]const u8 {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, in);
    const steps = 1 + rand.uintLessThan(usize, 4);
    for (0..steps) |_| {
        const b = out.items;
        if (b.len == 0) {
            try out.append(gpa, rand.int(u8));
            continue;
        }
        switch (rand.uintLessThan(u8, 7)) {
            // A byte flips.
            0 => b[rand.uintLessThan(usize, b.len)] ^= @as(u8, 1) << rand.int(u3),
            // A random byte.
            1 => b[rand.uintLessThan(usize, b.len)] = rand.int(u8),
            // A 32-bit number becomes a large or a small one.
            2 => if (b.len >= 4) {
                const at = rand.uintLessThan(usize, b.len - 3);
                const values = [_]u32{ 0, 1, 0x7f, 0xff, 0xffff, 0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff };
                std.mem.writeInt(u32, b[at..][0..4], values[rand.uintLessThan(usize, values.len)], .little);
            },
            // A range goes away.
            3 => {
                const at = rand.uintLessThan(usize, b.len);
                const n = @min(b.len - at, 1 + rand.uintLessThan(usize, 64));
                try out.replaceRange(gpa, at, n, &.{});
            },
            // A range comes twice.
            4 => {
                const at = rand.uintLessThan(usize, b.len);
                const n = @min(b.len - at, 1 + rand.uintLessThan(usize, 64));
                const copy = try gpa.dupe(u8, b[at..][0..n]);
                defer gpa.free(copy);
                try out.insertSlice(gpa, at, copy);
            },
            // The input is cut.
            5 => out.shrinkRetainingCapacity(rand.uintLessThan(usize, b.len)),
            // A special character of text formats.
            6 => {
                const chars = "\n\r\t {}[]()<>&*:-'\"#=;/\\\x00";
                b[rand.uintLessThan(usize, b.len)] = chars[rand.uintLessThan(usize, chars.len)];
            },
            else => unreachable,
        }
    }
    return out.items;
}

/// Runs `check` on each seed and on `n` random changes of the seeds.
fn run(comptime name: []const u8, seeds: []const []const u8, n: usize, check: *const fn (Allocator, []const u8) anyerror!void) !void {
    var prng: std.Random.DefaultPrng = .init(seed() ^ std.hash.Wyhash.hash(0, name));
    const rand = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..seeds.len + n) |i| {
        const input = if (i < seeds.len) seeds[i] else try mutate(rand, seeds[rand.uintLessThan(usize, seeds.len)], &buf, testing.allocator);
        var lim: Limited = .{ .parent = testing.allocator, .limit = memory_limit };
        check(lim.allocator(), input) catch |e| switch (e) {
            // A memory error of the limit is an answer too.
            error.OutOfMemory => {},
            else => return e,
        };
        if (lim.live != 0) {
            std.debug.print("fuzz {s}: {d} bytes leaked, input {d} bytes\n", .{ name, lim.live, input.len });
            return error.Leak;
        }
    }
}

// ---- the readers ----

fn checkZip(gpa: Allocator, bytes: []const u8) anyerror!void {
    const list = zipfile.readAll(gpa, bytes) catch return;
    zipfile.freeAll(gpa, list);
}

fn checkStl(gpa: Allocator, bytes: []const u8) anyerror!void {
    var m = Mesh.fromStl(gpa, bytes) catch return;
    m.deinit(gpa);
}

fn checkYaml(gpa: Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: yaml.Diagnostic = .{};
    _ = yaml.parse(arena.allocator(), text, &diag) catch return;
}

fn checkProject(gpa: Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: project.Diagnostic = .{};
    const p = project.parse(a, text, &diag) catch return;
    _ = project.plan(a, &p, &.{}) catch return;
}

fn checkToml(gpa: Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: toml.Diagnostic = .{};
    _ = toml.parse(arena.allocator(), text, &diag) catch return;
}

fn lookupNone(ctx: ?*const anyopaque, name: []const u8) ?expr.Value {
    _ = ctx;
    return if (name.len % 2 == 0) .{ .num = 2 } else .{ .text = "PLA" };
}

fn checkExpr(gpa: Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: expr.Diagnostic = .{};
    const n = expr.parse(arena.allocator(), text, &diag) catch return;
    _ = expr.eval(n, .{ .lookup = lookupNone }) catch return;
}

fn checkGcodeRead(gpa: Allocator, bytes: []const u8) anyerror!void {
    var r = gcode_read.Reader.parse(gpa, bytes) catch return;
    r.deinit();
}

fn checkRender(gpa: Allocator, text: []const u8) anyerror!void {
    var s: settings_mod.Settings = .{};
    s.engine.job_name = "cube.stl";
    const r = try s.resolve();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = gcode_vars.render(gpa, &out.writer, text, &.{ .r = &r, .layer_count = 10 }) catch return;
}

fn checkMqtt(gpa: Allocator, bytes: []const u8) anyerror!void {
    var r: mqtt.Reader = .{};
    defer r.deinit(gpa);
    // In two pieces, as from a socket.
    const half = bytes.len / 2;
    try r.feed(gpa, bytes[0..half]);
    while (r.next() catch return) |_| {}
    try r.feed(gpa, bytes[half..]);
    while (r.next() catch return) |p| {
        std.mem.doNotOptimizeAway(p.topic.len + p.payload.len);
    }
}

fn checkJpeg(gpa: Allocator, bytes: []const u8) anyerror!void {
    var r: bambu.JpegReader = .{};
    defer r.deinit(gpa);
    try r.feed(gpa, bytes);
    while (r.next() catch return) |j| std.mem.doNotOptimizeAway(j.len);
}

fn checkDiscovery(gpa: Allocator, bytes: []const u8) anyerror!void {
    var f: discovery.Finder = .init(gpa);
    defer f.deinit();
    _ = try f.feed(bytes);
    _ = f.query();
}

fn check3mf(gpa: Allocator, bytes: []const u8) anyerror!void {
    var l = threemf.read(gpa, bytes) catch return;
    l.deinit(gpa);
}

/// A font: each glyph of the text and its kerning, flattened.
fn checkFont(gpa: Allocator, bytes: []const u8) anyerror!void {
    const f = font.Font.init(bytes) catch return;
    var p = font.text(gpa, &f, "AVÉ ofi\n&@%", .{ .size = 5 }) catch |e| switch (e) {
        error.BadFont => return,
        else => return e,
    };
    p.deinit(gpa);
    _ = font.stemRatio(&f);
}

// ---- the seeds ----

const stl_ascii =
    \\solid cube
    \\facet normal 0 0 1
    \\ outer loop
    \\  vertex 0 0 0
    \\  vertex 1 0 0
    \\  vertex 1 1 0
    \\ endloop
    \\endfacet
    \\facet normal 0 0 1
    \\ outer loop
    \\  vertex 0 0 0
    \\  vertex 1 1 0
    \\  vertex 0 1 1e3
    \\ endloop
    \\endfacet
    \\endsolid cube
;

fn stlBinary(gpa: Allocator) ![]u8 {
    var m = try @import("mesh.zig").shapes.box(gpa, 10, 10, 10);
    defer m.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try m.writeStl(&out.writer);
    return out.toOwnedSlice();
}

const model_xml =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
    \\ <resources>
    \\  <object id="1" name="a &amp; b" type="model">
    \\   <metadata name="infill_sparse_density">20</metadata>
    \\   <mesh>
    \\    <vertices>
    \\     <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>
    \\    </vertices>
    \\    <triangles>
    \\     <triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/>
    \\    </triangles>
    \\   </mesh>
    \\  </object>
    \\  <object id="2" type="model"><components><component objectid="1" transform="1 0 0 0 1 0 0 0 1 5 5 0"/><component objectid="1"/></components></object>
    \\ </resources>
    \\ <build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 50 50 0"/></build>
    \\</model>
;

fn zipOf(gpa: Allocator, entries: []const zipfile.Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try zipfile.write(gpa, &out.writer, entries);
    return out.toOwnedSlice();
}

fn threeMf(gpa: Allocator, store: bool) ![]u8 {
    return zipOf(gpa, &.{
        .{ .name = "_rels/.rels", .data = @constCast("<Relationships><Relationship Target=\"/3D/3dmodel.model\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>"), .store = store },
        .{ .name = "3D/3dmodel.model", .data = @constCast(model_xml), .store = store },
        .{ .name = "Metadata/zslice_overrides.txt", .data = @constCast("0\t1\tproject.infill_sparse_density\t30\n"), .store = store },
    });
}

const gcode_sample =
    \\;FLAVOR:Marlin
    \\;LAYER_COUNT:2
    \\M140 S60
    \\M104 S200
    \\G28
    \\G92 E0
    \\;LAYER:0
    \\;TYPE:WALL-OUTER
    \\G1 F1500 X10 Y10 Z0.2 E0
    \\G1 X20 Y10 E0.5
    \\G2 X30 Y20 I5 J5 E1.0
    \\G3 X20 Y30 R10 E1.5
    \\;LAYER:1
    \\G1 Z0.4
    \\G1 X10 Y10 E2
    \\M83
    \\G1 X10 Y20 E0.4
    \\G91
    \\G1 X1 Y1 E0.1
    \\G90
    \\; filament_diameter = 1.75
    \\; nozzle_diameter = 0.4
    \\
;

const render_sample = "M140 S{bed_temp}\nM104 S{first_layer_nozzle_temp}\n{if filament_type[0] == \"PLA\"}M117 [filament_type]\n{elsif bed_temp > 50}M117 hot\n{else}M117 x\n{endif}\n{local z = max(1, 2) + min(3, [layer_height]) * 2; if z > 2 then z = z - 1; endif}G1 Z{z}\nM117 {job_name}\n";

fn mqttSample(gpa: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x20, 2, 0, 0 }); // CONNACK
    const topic = "device/X/report";
    const payload = "{\"print\":{\"nozzle_temper\":200}}";
    try out.append(gpa, 0x30);
    try out.append(gpa, @intCast(2 + topic.len + payload.len));
    try out.appendSlice(gpa, &.{ 0, topic.len });
    try out.appendSlice(gpa, topic);
    try out.appendSlice(gpa, payload);
    try out.appendSlice(gpa, &.{ 0x90, 3, 0, 1, 0 }); // SUBACK
    return out.toOwnedSlice(gpa);
}

fn jpegSample(gpa: Allocator) ![]u8 {
    const jpeg = [_]u8{ 0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..2) |_| {
        var head = [_]u8{0} ** 16;
        std.mem.writeInt(u32, head[0..4], jpeg.len, .little);
        try out.appendSlice(gpa, &head);
        try out.appendSlice(gpa, &jpeg);
    }
    return out.toOwnedSlice(gpa);
}

/// An mDNS answer: PTR, SRV, TXT, and A records of an OctoPrint, with a
/// compressed name.
const mdns_sample = [_]u8{
    0, 0, 0x84, 0, 0, 0, 0, 4, 0, 0, 0, 0,
    // PTR _octoprint._tcp.local -> deck._octoprint._tcp.local
    10, '_', 'o', 'c', 't', 'o', 'p', 'r', 'i', 'n', 't', 4, '_', 't', 'c', 'p', 5, 'l', 'o', 'c', 'a', 'l', 0,
    0, 12, 0, 1, 0, 0, 0, 120, 0, 7, 4, 'd', 'e', 'c', 'k', 0xc0, 12,
    // SRV deck._octoprint._tcp.local: port 80, host deck.local
    4, 'd', 'e', 'c', 'k', 0xc0, 12, 0, 33, 0, 1, 0, 0, 0, 120, 0, 14, 0, 0, 0, 0, 0, 80, 4, 'd', 'e', 'c', 'k', 0xc0, 32,
    // TXT path=/
    4, 'd', 'e', 'c', 'k', 0xc0, 12, 0, 16, 0, 1, 0, 0, 0, 120, 0, 7, 6, 'p', 'a', 't', 'h', '=', '/',
    // A deck.local 192.168.1.5
    4, 'd', 'e', 'c', 'k', 0xc0, 32, 0, 1, 0, 1, 0, 0, 0, 120, 0, 4, 192, 168, 1, 5,
};

const ssdp_sample = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nLocation: 192.168.1.42\r\nNT: urn:bambulab-com:device:3dprinter:1\r\nUSN: 01P00A123456789\r\nDevModel.bambu.com: C12\r\nDevName.bambu.com: Shop P1S 3\r\n\r\n";

/// Text that nests deep: a reader with recursion must stop it.
fn deep(gpa: Allocator, open: []const u8, middle: []const u8, close: []const u8, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..n) |_| try out.appendSlice(gpa, open);
    try out.appendSlice(gpa, middle);
    for (0..n) |_| try out.appendSlice(gpa, close);
    return out.toOwnedSlice(gpa);
}

fn deepYaml(gpa: Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..n) |i| {
        try out.appendNTimes(gpa, ' ', i);
        try out.appendSlice(gpa, "a:\n");
    }
    try out.appendNTimes(gpa, ' ', n);
    try out.appendSlice(gpa, "b: 1\n");
    return out.toOwnedSlice(gpa);
}

const project_sample =
    \\project: robot
    \\parts:
    \\  - name: Feet
    \\    files: [models/foot.stl]
    \\    count: 4
    \\    printer: taz
    \\    profile: taz/pla-0.20
    \\    material: roll-4
    \\    settings: &s {support_enable: false, infill_sparse_density: 20}
    \\  - name: Tower
    \\    files: [models/tower.stl, "a b.stl"]
    \\    printer: taz
    \\    profile: taz/pla-0.20
    \\    settings: *s
    \\    alone: true
    \\    variants:
    \\      - name: fine
    \\        profile: taz/pla-0.10
    \\      - name: fast
    \\        settings: {<<: *s, infill_sparse_density: 10}
    \\  - name: Case
    \\    files: case.stl
    \\    description: >
    \\      a folded
    \\      text
    \\    prebuilt: phenom/case.cbddlp
;

// ---- the tests ----

test "fuzz: zip" {
    const gpa = testing.allocator;
    const a = try threeMf(gpa, false);
    defer gpa.free(a);
    const b = try threeMf(gpa, true);
    defer gpa.free(b);
    const c = try bambu.gcode3mf(gpa, gcode_sample, "Benchy");
    defer gpa.free(c);
    try run("zip", &.{ a, b, c }, rounds(400), checkZip);
}

test "fuzz: stl" {
    const gpa = testing.allocator;
    const bin = try stlBinary(gpa);
    defer gpa.free(bin);
    try run("stl", &.{ stl_ascii, bin }, rounds(400), checkStl);
}

test "fuzz: yaml and printdeck.yml" {
    const gpa = testing.allocator;
    const deep_flow = try deep(gpa, "[", "1", "]", 100_000);
    defer gpa.free(deep_flow);
    const deep_map = try deep(gpa, "{a: ", "1", "}", 50_000);
    defer gpa.free(deep_map);
    const deep_block = try deepYaml(gpa, 3000);
    defer gpa.free(deep_block);
    const seeds = [_][]const u8{ project_sample,deep_flow, deep_map, deep_block, "a: &x [1, 2]\nb: *x\nc: {<<: *x}\n" };
    try run("yaml", &seeds, rounds(400), checkYaml);
    try run("project", &seeds, rounds(400), checkProject);
}

test "fuzz: toml" {
    const seeds = [_][]const u8{
        "# c\nname = \"a\\\"b\\n\"\n[machine]\nstart_gcode = '''\nG28\n'''\nbed = 1.5e2\non = true\nlit = 'x'\nml = \"\"\"\na\\tb\"\"\"\n",
    };
    try run("toml", &seeds, rounds(400), checkToml);
}

test "fuzz: formulas" {
    const gpa = testing.allocator;
    const deep_paren = try deep(gpa, "(", "1", ")", 100_000);
    defer gpa.free(deep_paren);
    const deep_neg = try deep(gpa, "-", "1", "", 100_000);
    defer gpa.free(deep_neg);
    const deep_call = try deep(gpa, "max(1, ", "1", ")", 50_000);
    defer gpa.free(deep_call);
    const seeds = [_][]const u8{ "max({a}, 2) * 3 + -{bb} / 4 % 5 ^ 2 >= 1 and not 0 or \"x\" == {c}", "if({a} > 1, 2, 3)", deep_paren, deep_neg, deep_call };
    try run("expr", &seeds, rounds(400), checkExpr);
}

test "fuzz: start G-code" {
    const gpa = testing.allocator;
    const deep_paren = try deep(gpa, "{", "1", "}", 20_000);
    defer gpa.free(deep_paren);
    const deep_expr = try deep(gpa, "(", "1", ")", 100_000);
    defer gpa.free(deep_expr);
    const in_block = try std.mem.concat(gpa, u8, &.{ "G1 Z{", deep_expr, "}\n" });
    defer gpa.free(in_block);
    const deep_if = try deep(gpa, "{if 1}", "G28\n", "{endif}", 5000);
    defer gpa.free(deep_if);
    try run("render", &.{ render_sample, deep_paren, in_block, deep_if }, rounds(400), checkRender);
}

test "fuzz: G-code import" {
    try run("gcode_read", &.{gcode_sample}, rounds(400), checkGcodeRead);
}

test "fuzz: MQTT and the camera of Bambu Lab printers" {
    const gpa = testing.allocator;
    const m = try mqttSample(gpa);
    defer gpa.free(m);
    try run("mqtt", &.{m}, rounds(400), checkMqtt);
    const j = try jpegSample(gpa);
    defer gpa.free(j);
    try run("jpeg", &.{j}, rounds(400), checkJpeg);
}

test "fuzz: discovery" {
    try run("discovery", &.{ &mdns_sample, ssdp_sample }, rounds(400), checkDiscovery);
}

test "fuzz: 3mf" {
    const gpa = testing.allocator;
    const a = try threeMf(gpa, true);
    defer gpa.free(a);
    try run("3mf", &.{a}, rounds(300), check3mf);
}

// ---- Cura profile stacks ----

const CuraFiles = struct {
    const names = [_][]const u8{
        "cura.json",                              "definitions/acme_box.def.json",
        "definitions/acme_box_extruder.def.json", "machine_settings.inst.cfg",
        "draft.inst.cfg",                         "fast.inst.cfg",
        "fast_e0.inst.cfg",                       "user.inst.cfg",
        "user_e0.inst.cfg",                       "gray.xml.fdm_material",
    };
    const data = [_][]const u8{
        @embedFile("testdata/cura_compare/cura.json"),
        @embedFile("testdata/cura_compare/acme_box.def.json"),
        @embedFile("testdata/cura_compare/acme_box_extruder.def.json"),
        @embedFile("testdata/cura_compare/machine_settings.inst.cfg"),
        @embedFile("testdata/cura_compare/draft.inst.cfg"),
        @embedFile("testdata/cura_compare/fast.inst.cfg"),
        @embedFile("testdata/cura_compare/fast_e0.inst.cfg"),
        @embedFile("testdata/cura_compare/user.inst.cfg"),
        @embedFile("testdata/cura_compare/user_e0.inst.cfg"),
        @embedFile("testdata/cura_compare/gray.xml.fdm_material"),
    };
    /// The file that the fuzz test changes, and its new bytes.
    var which: usize = 0;
    var changed: []const u8 = "";

    fn read(ctx: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const u8 {
        _ = ctx;
        _ = arena;
        for (names, data, 0..) |n, d, i| if (std.mem.eql(u8, n, path)) return if (i == which) changed else d;
        return null;
    }
};

fn checkCura(gpa: Allocator, bytes: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    CuraFiles.changed = bytes;
    var diag: import_cura.Diagnostic = .{};
    _ = import_cura.importStack(arena.allocator(), .{ .read = CuraFiles.read }, &diag) catch return;
}

test "fuzz: Cura profile stacks" {
    for (CuraFiles.data, 0..) |d, i| {
        CuraFiles.which = i;
        try run("cura", &.{d}, rounds(400) / CuraFiles.data.len + 1, checkCura);
    }
}

test "fuzz: fonts" {
    // The embedded font is 44 KB: fewer rounds than the small inputs.
    try run("font", &.{font.inter_bold}, rounds(60), checkFont);
}
