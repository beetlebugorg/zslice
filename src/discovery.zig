//! Printer discovery: find the printers on the local network with mDNS and
//! DNS-SD.
//!
//! A printer server announces a service on the network: a PTR record from
//! the service type (for example `_octoprint._tcp.local`) to its instance
//! name, an SRV record with the host and the port, a TXT record with
//! `key=value` pairs, and an A record with the IPv4 address of the host.
//! The finder sends one query for the PTR records of all service types to
//! the group 224.0.0.251, port 5353. Each server answers with its records.
//!
//! The core does no network I/O. A shell:
//!
//! 1. Sends `Finder.query` to 224.0.0.251:5353 from a UDP socket of its
//!    own port. A query from a port other than 5353 asks for a unicast
//!    answer to that port (RFC 6762, section 6.7), so the shell needs no
//!    multicast membership.
//! 2. Gives each packet that comes back to `Finder.feed`.
//! 3. Asks each new printer for more: `GET <url>/api/version` for an
//!    OctoPrint service, and `GET <url>/printer/objects/query?toolhead`
//!    for Moonraker. `Finder.reply` reads the answer. The version text
//!    tells printdeck and PrusaLink from OctoPrint (both announce
//!    `_octoprint._tcp`), and the toolhead of Klipper tells the size of
//!    the bed.
//!
//! The service types:
//!
//! - `_octoprint._tcp`: OctoPrint (its discovery plugin), printdeck (a
//!   systemd-resolved service file, with the name of the deck), and
//!   PrusaLink (for older slicers).
//! - `_moonraker._tcp`: Moonraker, the API server of Klipper (its
//!   zeroconf component). The TXT record has its version.
//! - `_prusalink._tcp`: PrusaLink.
//!
//! One printer can announce more than one service at the same address and
//! port (PrusaLink announces `_prusalink` and `_octoprint`). The finder
//! keeps one entry for each address and port, with the most exact kind.
//!
//! References (see REFERENCES.md): RFC 1035 (DNS messages and name
//! compression), RFC 6762 (mDNS), RFC 6763 (DNS-SD), the OctoPrint
//! discovery plugin, the Moonraker zeroconf component, PrusaLink, and the
//! printdeck service file.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum(c_int) {
    octoprint = 1,
    printdeck = 2,
    moonraker = 3,
    prusalink = 4,

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .octoprint => "OctoPrint",
            .printdeck => "printdeck",
            .moonraker => "Moonraker (Klipper)",
            .prusalink => "PrusaLink",
        };
    }

    /// The rank of a kind for one address: a more exact kind wins.
    fn rank(k: Kind) u8 {
        return switch (k) {
            .octoprint => 0,
            .moonraker => 1,
            .printdeck => 2,
            .prusalink => 2,
        };
    }
};

pub const services = [_]struct { name: []const u8, kind: Kind }{
    .{ .name = "_octoprint._tcp.local", .kind = .octoprint },
    .{ .name = "_moonraker._tcp.local", .kind = .moonraker },
    .{ .name = "_prusalink._tcp.local", .kind = .prusalink },
};

pub const group_address = [4]u8{ 224, 0, 0, 251 };
pub const port: u16 = 5353;

/// A printer that the finder found.
pub const Found = struct {
    /// The instance name, for example "Printdeck" or "PrusaLink at mk4".
    name: [:0]const u8 = "",
    kind: Kind,
    /// The host name, for example "printdeck.local".
    host: [:0]const u8 = "",
    /// The IPv4 address, for example "192.168.1.20".
    address: [:0]const u8 = "",
    port: u16 = 80,
    /// The path prefix of the API (TXT `path`), "" for none.
    path: [:0]const u8 = "",
    /// The base URL of the API, for example "http://192.168.1.20:80".
    url: [:0]const u8 = "",
    /// TXT `model`, the model of the printer, if the server tells it.
    model: [:0]const u8 = "",
    /// TXT `version`, or the version text of the API.
    version: [:0]const u8 = "",
    /// The bed (Klipper axis limits), 0 when not known.
    bed_x: f64 = 0,
    bed_y: f64 = 0,
    height: f64 = 0,
    origin_x: f64 = 0,
    origin_y: f64 = 0,
};

pub const Reply = enum(c_int) {
    /// The body of GET <url>/api/version (the OctoPrint API).
    version = 1,
    /// The body of GET <url>/printer/objects/query?toolhead (Moonraker).
    toolhead = 2,
};

pub const Finder = struct {
    arena: std.heap.ArenaAllocator,
    found: std.ArrayList(Found) = .empty,
    /// What the packets told so far, by name.
    srv: std.StringHashMapUnmanaged(Srv) = .empty,
    txt: std.StringHashMapUnmanaged(Txt) = .empty,
    addr: std.StringHashMapUnmanaged([4]u8) = .empty,
    /// Each instance name from a PTR record, with its kind.
    instances: std.StringArrayHashMapUnmanaged(Kind) = .empty,
    query_buf: [128]u8 = undefined,
    query_len: usize = 0,

    const Srv = struct { host: []const u8, port: u16 };
    const Txt = struct { path: []const u8 = "", model: []const u8 = "", version: []const u8 = "" };

    pub fn init(gpa: Allocator) Finder {
        var f: Finder = .{ .arena = .init(gpa) };
        f.query_len = buildQuery(&f.query_buf) catch unreachable;
        return f;
    }

    pub fn deinit(self: *Finder) void {
        self.arena.deinit();
    }

    /// The query packet for all service types.
    pub fn query(self: *const Finder) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    /// Reads a packet. `from` is the IPv4 address of the sender, for a
    /// host with no A record in the packet. Returns true if the list of
    /// printers changed. A packet that is not a valid answer changes
    /// nothing.
    pub fn feed(self: *Finder, packet: []const u8, from: ?[4]u8) Allocator.Error!bool {
        const a = self.arena.allocator();
        var msg = Message.init(packet) catch return false;
        if (!msg.response) return false;
        var rr_count: usize = @as(usize, msg.answers) + msg.authority + msg.additional;
        var sender_host: ?[]const u8 = null;
        while (rr_count > 0) : (rr_count -= 1) {
            const rr = msg.record(a) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            switch (rr.type) {
                12 => { // PTR
                    const kind = for (services) |s| {
                        if (std.ascii.eqlIgnoreCase(rr.name, s.name)) break s.kind;
                    } else continue;
                    const target = msg.nameAt(a, rr.data_pos) catch continue;
                    const gop = try self.instances.getOrPut(a, target);
                    if (!gop.found_existing) gop.value_ptr.* = kind;
                },
                33 => { // SRV: priority, weight, port, target
                    if (rr.data.len < 7) continue;
                    const p = std.mem.readInt(u16, rr.data[4..6], .big);
                    const host = msg.nameAt(a, rr.data_pos + 6) catch continue;
                    try self.srv.put(a, try lower(a, rr.name), .{ .host = host, .port = p });
                    sender_host = host;
                },
                16 => try self.txt.put(a, try lower(a, rr.name), try parseTxt(a, rr.data)),
                1 => if (rr.data.len == 4) try self.addr.put(a, try lower(a, rr.name), rr.data[0..4].*),
                else => {},
            }
        }
        // A host with no A record: the sender of the packet.
        if (from) |f| if (sender_host) |h| {
            const key = try lower(a, h);
            if (self.addr.get(key) == null) try self.addr.put(a, key, f);
        };
        return self.rebuild();
    }

    /// Makes the list of printers from the records so far. Returns true if
    /// it changed.
    fn rebuild(self: *Finder) Allocator.Error!bool {
        const a = self.arena.allocator();
        var changed = false;
        var it = self.instances.iterator();
        while (it.next()) |e| {
            const inst = e.key_ptr.*;
            const key = try lower(a, inst);
            const srv = self.srv.get(key) orelse continue;
            const ip = self.addr.get(try lower(a, srv.host)) orelse continue;
            const txt = self.txt.get(key) orelse Txt{};
            const address = try std.fmt.allocPrintSentinel(a, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }, 0);
            // One entry for each address and port.
            const existing = for (self.found.items) |*f| {
                if (std.mem.eql(u8, f.address, address) and f.port == srv.port) break f;
            } else null;
            if (existing) |f| {
                if (e.value_ptr.rank() > f.kind.rank()) {
                    f.kind = e.value_ptr.*;
                    f.name = try instanceLabel(a, inst);
                    changed = true;
                }
                if (f.model.len == 0 and txt.model.len > 0) {
                    f.model = try a.dupeZ(u8, txt.model);
                    changed = true;
                }
                continue;
            }
            const path = std.mem.trimEnd(u8, txt.path, "/");
            const host = std.mem.trimEnd(u8, srv.host, ".");
            try self.found.append(a, .{
                .name = try instanceLabel(a, inst),
                .kind = e.value_ptr.*,
                .host = try a.dupeZ(u8, host),
                .address = address,
                .port = srv.port,
                .path = try a.dupeZ(u8, path),
                .url = if (srv.port == 80)
                    try std.fmt.allocPrintSentinel(a, "http://{s}{s}", .{ address, path }, 0)
                else
                    try std.fmt.allocPrintSentinel(a, "http://{s}:{d}{s}", .{ address, srv.port, path }, 0),
                .model = try a.dupeZ(u8, txt.model),
                .version = try a.dupeZ(u8, txt.version),
            });
            changed = true;
        }
        return changed;
    }

    /// Reads the answer of a printer to a request of `what`. Returns true
    /// if the entry changed.
    pub fn reply(self: *Finder, i: usize, what: Reply, body: []const u8) Allocator.Error!bool {
        if (i >= self.found.items.len) return false;
        const a = self.arena.allocator();
        const f = &self.found.items[i];
        switch (what) {
            .version => {
                const text = versionText(a, body) orelse return false;
                const kind = kindFromVersion(text) orelse return false;
                const changed = kind != f.kind or !std.mem.eql(u8, f.version, text);
                if (kind.rank() >= f.kind.rank()) f.kind = kind;
                f.version = try a.dupeZ(u8, text);
                return changed;
            },
            .toolhead => {
                const bed = toolheadBed(a, body) orelse return false;
                f.bed_x = bed[0];
                f.bed_y = bed[1];
                f.height = bed[2];
                f.origin_x = bed[3];
                f.origin_y = bed[4];
                return true;
            },
        }
    }
};

/// The kind of an OctoPrint API server from the `text` of /api/version:
/// "OctoPrint 1.11.0 (Printdeck v0.4.0)", "PrusaLink 0.7.0", or
/// "OctoPrint 1.10.2".
pub fn kindFromVersion(text: []const u8) ?Kind {
    if (std.ascii.indexOfIgnoreCase(text, "printdeck") != null) return .printdeck;
    if (std.ascii.indexOfIgnoreCase(text, "prusalink") != null) return .prusalink;
    if (std.ascii.indexOfIgnoreCase(text, "octoprint") != null) return .octoprint;
    return null;
}

/// The "text" of a JSON answer of /api/version, or null.
fn versionText(a: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return null;
    if (parsed != .object) return null;
    const t = parsed.object.get("text") orelse parsed.object.get("server") orelse return null;
    return if (t == .string) t.string else null;
}

/// The bed of a Klipper printer from the toolhead object of Moonraker:
/// x, y, and z size, and the x and y of the minimum (the origin).
fn toolheadBed(a: Allocator, body: []const u8) ?[5]f64 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return null;
    const result = field(parsed, "result") orelse return null;
    const status = field(result, "status") orelse return null;
    const th = field(status, "toolhead") orelse return null;
    const lo = field(th, "axis_minimum") orelse return null;
    const hi = field(th, "axis_maximum") orelse return null;
    if (lo != .array or hi != .array or lo.array.items.len < 3 or hi.array.items.len < 3) return null;
    var v: [6]f64 = undefined;
    for (0..3) |k| {
        v[k] = number(lo.array.items[k]) orelse return null;
        v[3 + k] = number(hi.array.items[k]) orelse return null;
    }
    const x = v[3] - v[0];
    const y = v[4] - v[1];
    const z = v[5] - @max(v[2], 0);
    if (!(x > 10 and y > 10 and z > 10)) return null;
    return .{ x, y, z, v[0], v[1] };
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

/// The instance label of a full instance name: "Printdeck" from
/// "Printdeck._octoprint._tcp.local".
fn instanceLabel(a: Allocator, name: []const u8) Allocator.Error![:0]const u8 {
    for (services) |s| {
        if (name.len > s.name.len + 1 and std.ascii.endsWithIgnoreCase(name, s.name)) return a.dupeZ(u8, name[0 .. name.len - s.name.len - 1]);
    }
    return a.dupeZ(u8, name);
}

fn lower(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const out = try a.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn parseTxt(a: Allocator, data: []const u8) Allocator.Error!Finder.Txt {
    var t: Finder.Txt = .{};
    var i: usize = 0;
    while (i < data.len) {
        const n = data[i];
        i += 1;
        if (i + n > data.len) break;
        const kv = data[i .. i + n];
        i += n;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = try a.dupe(u8, kv[eq + 1 ..]);
        if (std.ascii.eqlIgnoreCase(k, "path")) t.path = v else if (std.ascii.eqlIgnoreCase(k, "model")) t.model = v else if (std.ascii.eqlIgnoreCase(k, "version")) t.version = v;
    }
    return t;
}

/// Writes the query: one question (PTR, class IN, unicast answer) for each
/// service type.
pub fn buildQuery(buf: []u8) error{NoSpaceLeft}!usize {
    var n: usize = 0;
    const put = struct {
        fn f(b: []u8, at: *usize, bytes: []const u8) error{NoSpaceLeft}!void {
            if (at.* + bytes.len > b.len) return error.NoSpaceLeft;
            @memcpy(b[at.* .. at.* + bytes.len], bytes);
            at.* += bytes.len;
        }
    }.f;
    // Header: id 0, flags 0 (a standard query), the question count.
    try put(buf, &n, &.{ 0, 0, 0, 0, 0, @intCast(services.len), 0, 0, 0, 0, 0, 0 });
    for (services) |s| {
        var labels = std.mem.splitScalar(u8, s.name, '.');
        while (labels.next()) |l| {
            try put(buf, &n, &.{@intCast(l.len)});
            try put(buf, &n, l);
        }
        // The root, type PTR (12), class IN (1) with the unicast bit.
        try put(buf, &n, &.{ 0, 0, 12, 0x80, 1 });
    }
    return n;
}

/// A DNS message (RFC 1035, section 4).
const Message = struct {
    data: []const u8,
    pos: usize,
    response: bool,
    answers: u16,
    authority: u16,
    additional: u16,

    const Error = error{ Truncated, BadName, OutOfMemory };

    fn init(data: []const u8) Error!Message {
        if (data.len < 12) return error.Truncated;
        var m: Message = .{
            .data = data,
            .pos = 12,
            .response = data[2] & 0x80 != 0,
            .answers = std.mem.readInt(u16, data[6..8], .big),
            .authority = std.mem.readInt(u16, data[8..10], .big),
            .additional = std.mem.readInt(u16, data[10..12], .big),
        };
        // Skip the questions (a unicast answer repeats them).
        var q = std.mem.readInt(u16, data[4..6], .big);
        while (q > 0) : (q -= 1) {
            m.pos = try m.skipName(m.pos);
            m.pos += 4;
            if (m.pos > data.len) return error.Truncated;
        }
        return m;
    }

    const Record = struct { name: []const u8, type: u16, data: []const u8, data_pos: usize };

    fn record(self: *Message, a: Allocator) Error!Record {
        const name = try self.nameAt(a, self.pos);
        self.pos = try self.skipName(self.pos);
        if (self.pos + 10 > self.data.len) return error.Truncated;
        const t = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        const len = std.mem.readInt(u16, self.data[self.pos + 8 ..][0..2], .big);
        const start = self.pos + 10;
        if (start + len > self.data.len) return error.Truncated;
        self.pos = start + len;
        return .{ .name = name, .type = t, .data = self.data[start .. start + len], .data_pos = start };
    }

    /// The position after the name at `at`.
    fn skipName(self: *const Message, at: usize) Error!usize {
        var p = at;
        while (true) {
            if (p >= self.data.len) return error.Truncated;
            const n = self.data[p];
            if (n == 0) return p + 1;
            if (n & 0xc0 == 0xc0) return p + 2;
            if (n & 0xc0 != 0) return error.BadName;
            p += 1 + n;
        }
    }

    /// The name at `at`, with its labels joined by dots, after the
    /// compression pointers (at most 32, so a loop ends).
    fn nameAt(self: *const Message, a: Allocator, at: usize) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var p = at;
        var jumps: usize = 0;
        while (true) {
            if (p >= self.data.len) return error.Truncated;
            const n = self.data[p];
            if (n == 0) break;
            if (n & 0xc0 == 0xc0) {
                if (p + 1 >= self.data.len) return error.Truncated;
                jumps += 1;
                if (jumps > 32) return error.BadName;
                p = (@as(usize, n & 0x3f) << 8) | self.data[p + 1];
                continue;
            }
            if (n & 0xc0 != 0) return error.BadName;
            if (p + 1 + n > self.data.len) return error.Truncated;
            if (out.items.len > 0) try out.append(a, '.');
            try out.appendSlice(a, self.data[p + 1 .. p + 1 + n]);
            if (out.items.len > 255) return error.BadName;
            p += 1 + n;
        }
        return out.items;
    }
};

// ---- tests ----

const testing = std.testing;

/// Writes a name with no compression.
fn testName(out: *std.ArrayList(u8), name: []const u8) !void {
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |l| {
        try out.append(testing.allocator, @intCast(l.len));
        try out.appendSlice(testing.allocator, l);
    }
    try out.append(testing.allocator, 0);
}

fn testRecord(out: *std.ArrayList(u8), name: []const u8, t: u16, data: []const u8) !void {
    try testName(out, name);
    var head: [10]u8 = undefined;
    std.mem.writeInt(u16, head[0..2], t, .big);
    std.mem.writeInt(u16, head[2..4], 0x8001, .big);
    std.mem.writeInt(u32, head[4..8], 120, .big);
    std.mem.writeInt(u16, head[8..10], @intCast(data.len), .big);
    try out.appendSlice(testing.allocator, &head);
    try out.appendSlice(testing.allocator, data);
}

/// An answer of one service: PTR, SRV, TXT, and A.
fn testAnswer(service: []const u8, instance: []const u8, host: []const u8, p: u16, txt: []const []const u8, ip: ?[4]u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, &.{ 0, 0, 0x84, 0, 0, 0, 0, 3, 0, 0, 0, @as(u8, if (ip != null) 1 else 0) });
    const full = try std.fmt.allocPrint(testing.allocator, "{s}.{s}", .{ instance, service });
    defer testing.allocator.free(full);
    // PTR: the instance name.
    var ptr: std.ArrayList(u8) = .empty;
    defer ptr.deinit(testing.allocator);
    try testName(&ptr, full);
    try testRecord(&out, service, 12, ptr.items);
    // SRV: priority 0, weight 0, port, host.
    var srv: std.ArrayList(u8) = .empty;
    defer srv.deinit(testing.allocator);
    try srv.appendSlice(testing.allocator, &.{ 0, 0, 0, 0, @intCast(p >> 8), @intCast(p & 0xff) });
    try testName(&srv, host);
    try testRecord(&out, full, 33, srv.items);
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(testing.allocator);
    for (txt) |kv| {
        try t.append(testing.allocator, @intCast(kv.len));
        try t.appendSlice(testing.allocator, kv);
    }
    try testRecord(&out, full, 16, t.items);
    if (ip) |addr| try testRecord(&out, host, 1, &addr);
    return out.toOwnedSlice(testing.allocator);
}

test "the query asks for each service type" {
    var buf: [128]u8 = undefined;
    const n = try buildQuery(&buf);
    var f = Finder.init(testing.allocator);
    defer f.deinit();
    try testing.expectEqualSlices(u8, buf[0..n], f.query());
    try testing.expectEqual(@as(u8, services.len), buf[5]);
    // The first question: _octoprint._tcp.local, PTR, IN with the unicast bit.
    try testing.expectEqualSlices(u8, "\x0a_octoprint\x04_tcp\x05local\x00\x00\x0c\x80\x01", buf[12 .. 12 + 27]);
    // A query is not an answer.
    try testing.expect(!try f.feed(buf[0..n], null));
}

test "find a printdeck and a Klipper printer" {
    var f = Finder.init(testing.allocator);
    defer f.deinit();
    const deck = try testAnswer("_octoprint._tcp.local", "Printdeck", "printdeck.local", 80, &.{ "path=/", "api=0.1", "version=1.11.0" }, .{ 192, 168, 1, 20 });
    defer testing.allocator.free(deck);
    try testing.expect(try f.feed(deck, null));
    try testing.expectEqual(@as(usize, 1), f.found.items.len);
    const d = f.found.items[0];
    try testing.expectEqualStrings("Printdeck", d.name);
    try testing.expectEqual(Kind.octoprint, d.kind);
    try testing.expectEqualStrings("192.168.1.20", d.address);
    try testing.expectEqualStrings("http://192.168.1.20", d.url);
    try testing.expectEqualStrings("printdeck.local", d.host);
    // The same packet again changes nothing.
    try testing.expect(!try f.feed(deck, null));
    // /api/version tells that it is a printdeck.
    try testing.expect(try f.reply(0, .version, "{\"api\":\"0.1\",\"server\":\"1.11.0\",\"text\":\"OctoPrint 1.11.0 (Printdeck v0.4.0-beta)\"}"));
    try testing.expectEqual(Kind.printdeck, f.found.items[0].kind);

    // A Moonraker answer with no A record: the address of the sender.
    const kl = try testAnswer("_moonraker._tcp.local", "Moonraker-1a2b3c4d @ voron", "voron.local", 7125, &.{"version=v0.9.3"}, null);
    defer testing.allocator.free(kl);
    try testing.expect(try f.feed(kl, .{ 10, 0, 0, 7 }));
    const k = f.found.items[1];
    try testing.expectEqual(Kind.moonraker, k.kind);
    try testing.expectEqualStrings("http://10.0.0.7:7125", k.url);
    try testing.expectEqualStrings("v0.9.3", k.version);
    try testing.expect(try f.reply(1, .toolhead, "{\"result\":{\"eventtime\":1,\"status\":{\"toolhead\":{\"axis_minimum\":[0.0,-5.0,-2.0,-1e9],\"axis_maximum\":[350.0,350.0,340.0,1e9]}}}}"));
    try testing.expectEqual(@as(f64, 350), f.found.items[1].bed_x);
    try testing.expectEqual(@as(f64, 355), f.found.items[1].bed_y);
    try testing.expectEqual(@as(f64, -5), f.found.items[1].origin_y);
    try testing.expectEqual(@as(f64, 340), f.found.items[1].height);
}

test "one entry for each address: the exact kind wins" {
    var f = Finder.init(testing.allocator);
    defer f.deinit();
    const octo = try testAnswer("_octoprint._tcp.local", "PrusaLink at mk4", "mk4.local", 80, &.{"path=/"}, .{ 192, 168, 1, 30 });
    defer testing.allocator.free(octo);
    const link = try testAnswer("_prusalink._tcp.local", "PrusaLink at mk4", "mk4.local", 80, &.{ "path=/", "model=MK4" }, .{ 192, 168, 1, 30 });
    defer testing.allocator.free(link);
    _ = try f.feed(octo, null);
    _ = try f.feed(link, null);
    try testing.expectEqual(@as(usize, 1), f.found.items.len);
    try testing.expectEqual(Kind.prusalink, f.found.items[0].kind);
    try testing.expectEqualStrings("MK4", f.found.items[0].model);
}

test "bad packets change nothing" {
    var f = Finder.init(testing.allocator);
    defer f.deinit();
    try testing.expect(!try f.feed("", null));
    try testing.expect(!try f.feed(&.{ 0, 0, 0x84, 0, 0, 0, 0, 5, 0, 0, 0, 0 }, null));
    // A compression pointer to itself.
    try testing.expect(!try f.feed(&.{ 0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xc0, 12, 0, 12, 0, 1, 0, 0, 0, 0, 0, 0 }, null));
    // Every cut of a good answer.
    const deck = try testAnswer("_octoprint._tcp.local", "Printdeck", "printdeck.local", 80, &.{"path=/"}, .{ 192, 168, 1, 20 });
    defer testing.allocator.free(deck);
    for (0..deck.len) |n| _ = try f.feed(deck[0..n], null);
    try testing.expect(!try f.reply(5, .version, "{}"));
    try testing.expect(!try f.reply(0, .version, "not json"));
}

test "the kind from the version text" {
    try testing.expectEqual(Kind.printdeck, kindFromVersion("OctoPrint 1.11.0 (Printdeck v0.4.0)").?);
    try testing.expectEqual(Kind.prusalink, kindFromVersion("PrusaLink 0.7.2").?);
    try testing.expectEqual(Kind.octoprint, kindFromVersion("OctoPrint 1.10.3").?);
    try testing.expectEqual(@as(?Kind, null), kindFromVersion("nginx"));
}
