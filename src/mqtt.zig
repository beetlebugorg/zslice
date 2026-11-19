//! A small MQTT 3.1.1 client codec, for the status of Bambu Lab printers
//! in LAN mode (bambu.zig). The shell owns the TLS socket. It writes the
//! packets that this file makes, and feeds each byte that it reads to a
//! `Reader`, which gives back whole packets.
//!
//! An MQTT packet is a fixed header (the type in the high 4 bits of the
//! first byte, flags in the low 4 bits), the remaining length (7 bits in
//! each byte, the high bit set when another byte follows, at most 4
//! bytes), and the body. Strings are a big endian u16 length and the
//! bytes.
//!
//! The client makes CONNECT, SUBSCRIBE, PINGREQ, and DISCONNECT. It makes
//! no PUBLISH: the read-only link of an app never sends a command to a
//! printer. The packets follow MQTT Version 3.1.1 (OASIS Standard), see
//! REFERENCES.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const connect = 1;
pub const connack = 2;
pub const publish = 3;
pub const suback = 9;
pub const pingresp = 13;

pub const ping_packet = [_]u8{ 0xC0, 0 };
pub const disconnect_packet = [_]u8{ 0xE0, 0 };

fn putLen(out: *std.ArrayList(u8), gpa: Allocator, len: usize) Allocator.Error!void {
    var n = len;
    while (true) {
        var d: u8 = @intCast(n % 128);
        n /= 128;
        if (n > 0) d |= 128;
        try out.append(gpa, d);
        if (n == 0) break;
    }
}

fn putStr(body: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    const n: u16 = @intCast(@min(s.len, 65535));
    try body.append(gpa, @intCast(n >> 8));
    try body.append(gpa, @intCast(n & 255));
    try body.appendSlice(gpa, s[0..n]);
}

fn packet(gpa: Allocator, first: u8, body: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, first);
    try putLen(&out, gpa, body.len);
    try out.appendSlice(gpa, body);
    return out.toOwnedSlice(gpa);
}

/// CONNECT: protocol level 4, a clean session, a user and a password.
pub fn connectPacket(gpa: Allocator, client_id: []const u8, user: []const u8, password: []const u8, keepalive_s: u16) Allocator.Error![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try putStr(&body, gpa, "MQTT");
    try body.appendSlice(gpa, &.{ 4, 0xC2, @intCast(keepalive_s >> 8), @intCast(keepalive_s & 255) });
    try putStr(&body, gpa, client_id);
    try putStr(&body, gpa, user);
    try putStr(&body, gpa, password);
    return packet(gpa, 0x10, body.items);
}

/// SUBSCRIBE to one topic at QoS 0.
pub fn subscribePacket(gpa: Allocator, packet_id: u16, topic: []const u8) Allocator.Error![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &.{ @intCast(packet_id >> 8), @intCast(packet_id & 255) });
    try putStr(&body, gpa, topic);
    try body.append(gpa, 0);
    return packet(gpa, 0x82, body.items);
}

pub const Packet = struct {
    /// The packet type (1 to 14).
    kind: u8,
    flags: u8,
    body: []const u8,
    /// CONNACK: the return code (0 accepted, 4 bad user or password, 5 not
    /// authorized); 255 for other packets.
    return_code: u8 = 255,
    /// PUBLISH: the topic and the payload.
    topic: []const u8 = "",
    payload: []const u8 = "",
};

pub const Error = error{BadPacket} || Allocator.Error;

/// Collects the bytes of the stream and gives back each whole packet. The
/// slices of a packet stay valid until the next `feed` or `next`.
pub const Reader = struct {
    buf: std.ArrayList(u8) = .empty,
    /// The bytes of the last packet, removed at the next call.
    used: usize = 0,

    pub fn deinit(r: *Reader, gpa: Allocator) void {
        r.buf.deinit(gpa);
    }

    fn drop(r: *Reader) void {
        if (r.used == 0) return;
        const rest = r.buf.items.len - r.used;
        std.mem.copyForwards(u8, r.buf.items[0..rest], r.buf.items[r.used..]);
        r.buf.items.len = rest;
        r.used = 0;
    }

    pub fn feed(r: *Reader, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        r.drop();
        try r.buf.appendSlice(gpa, bytes);
    }

    /// The next whole packet, or null when more bytes must come.
    pub fn next(r: *Reader) Error!?Packet {
        r.drop();
        const b = r.buf.items;
        if (b.len < 2) return null;
        var len: usize = 0;
        var mult: usize = 1;
        var i: usize = 1;
        while (true) : (i += 1) {
            if (i > 4) return error.BadPacket;
            if (i >= b.len) return null;
            len += (b[i] & 127) * mult;
            mult *= 128;
            if (b[i] & 128 == 0) break;
        }
        const start = i + 1;
        if (b.len < start + len) return null;
        r.used = start + len;
        var p: Packet = .{ .kind = b[0] >> 4, .flags = b[0] & 15, .body = b[start .. start + len] };
        switch (p.kind) {
            connack => {
                if (len < 2) return error.BadPacket;
                p.return_code = p.body[1];
            },
            publish => {
                if (len < 2) return error.BadPacket;
                const tl = @as(usize, p.body[0]) << 8 | p.body[1];
                // QoS 1 and 2 have a packet id after the topic.
                const at = 2 + tl + @as(usize, if ((p.flags >> 1) & 3 != 0) 2 else 0);
                if (at > len) return error.BadPacket;
                p.topic = p.body[2 .. 2 + tl];
                p.payload = p.body[at..];
            },
            else => {},
        }
        return p;
    }
};

const testing = std.testing;

test "mqtt: connect, subscribe, and a report in two pieces" {
    const gpa = testing.allocator;
    const c = try connectPacket(gpa, "zslice-1", "bblp", "12345678", 60);
    defer gpa.free(c);
    try testing.expectEqual(@as(u8, 0x10), c[0]);
    try testing.expectEqual(@as(usize, c.len - 2), c[1]);
    try testing.expectEqualStrings("MQTT", c[4..8]);
    const s = try subscribePacket(gpa, 1, "device/01P00A123456789/report");
    defer gpa.free(s);
    try testing.expectEqual(@as(u8, 0x82), s[0]);
    try testing.expectEqual(@as(u8, 0), s[s.len - 1]);

    var r: Reader = .{};
    defer r.deinit(gpa);
    try r.feed(gpa, &.{ 0x20, 2, 0, 0 });
    const ack = (try r.next()).?;
    try testing.expectEqual(@as(u8, connack), ack.kind);
    try testing.expectEqual(@as(u8, 0), ack.return_code);
    try testing.expect((try r.next()) == null);
    // A PUBLISH of 200 bytes: the length has two bytes.
    const topic = "device/x/report";
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try putStr(&body, gpa, topic);
    try body.appendNTimes(gpa, 'a', 200 - body.items.len);
    try msg.append(gpa, 0x30);
    try putLen(&msg, gpa, body.items.len);
    try msg.appendSlice(gpa, body.items);
    try r.feed(gpa, msg.items[0..50]);
    try testing.expect((try r.next()) == null);
    try r.feed(gpa, msg.items[50..]);
    const p = (try r.next()).?;
    try testing.expectEqual(@as(u8, publish), p.kind);
    try testing.expectEqualStrings(topic, p.topic);
    try testing.expectEqual(@as(usize, 200 - 2 - topic.len), p.payload.len);
    try testing.expect((try r.next()) == null);
}
