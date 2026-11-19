//! A small RTSP client codec for the camera of a Bambu Lab printer (RTSP
//! over TLS on port 322, H.264 video). The shell owns the TLS socket. It
//! writes the bytes of `Session.output`, and feeds each byte that it reads
//! to `Session.feed`, which answers with new requests and whole video
//! frames. No I/O happens here.
//!
//! The session (RFC 2326, RTSP 1.0):
//!
//! 1. DESCRIBE the url, with Accept: application/sdp. The answer is an SDP
//!    text (RFC 4566): the H.264 track (a=rtpmap ... H264/90000), its
//!    control url (a=control), and often its parameter sets
//!    (a=fmtp ... sprop-parameter-sets, base64).
//! 2. SETUP the track with Transport: RTP/AVP/TCP;interleaved=0-1, so the
//!    video comes on the same connection. The answer has a Session id.
//! 3. PLAY the url of the session. After that, the server sends each RTP
//!    packet as '$', a channel byte, a big endian u16 length, and the
//!    packet. Channel 0 is RTP, channel 1 is RTCP (skipped here).
//!
//! A 401 answer asks for a login. The session sends the request once more
//! with an Authorization header: Digest (RFC 2617, MD5, with or without
//! qop=auth) when the server offers it, else Basic. A second 401 fails.
//!
//! H.264 over RTP (RFC 6184): a packet holds one NAL unit (types 1 to
//! 23), several (STAP-A, type 24: each with a u16 size), or a fragment of
//! one (FU-A, type 28: a start bit, an end bit, and the type). The packets
//! of one frame share an RTP timestamp, and the last one has the marker
//! bit. A frame (an access unit) comes out in Annex B form: each NAL unit
//! after the start code 00 00 00 01. A key frame (with an IDR slice, type
//! 5) gets the parameter sets (SPS 7, PPS 8) in front when it lacks them,
//! so a decoder can start there. A lost packet (a gap in the sequence
//! numbers) drops its frame and the frames up to the next key frame,
//! which a decoder could not show right.
//!
//! Each length from the network is bounded: a header block of 16 KiB, a
//! body of 64 KiB, a frame of 4 MiB, and 32 frames that wait. Over a
//! bound, the session fails (a header or a body) or drops the frame (the
//! video). See REFERENCES.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const Md5 = std.crypto.hash.Md5;
const b64 = std.base64.standard;

pub const max_head = 16 * 1024;
pub const max_body = 64 * 1024;
pub const max_frame = 4 * 1024 * 1024;
pub const max_frames = 32;
/// A Session id, a realm, a nonce, or a url from the server.
const max_text = 1024;

pub const State = enum(i8) {
    connecting = 0,
    playing = 1,
    failed = -1,
};

/// Why a session failed.
pub const Failure = enum(u8) {
    none,
    /// A second 401: the user or the access code is wrong.
    auth,
    /// 404: no stream at the url (the camera can be off).
    not_found,
    /// Another error status of the server.
    refused,
    /// An answer that is not RTSP.
    bad_reply,
    /// An SDP with no H.264 video.
    no_video,
    /// A header block or a body over its bound.
    too_big,
};

pub fn failureText(f: Failure) [:0]const u8 {
    return switch (f) {
        .none => "",
        .auth => "The printer refused the access code for its camera.",
        .not_found => "The printer has no camera stream now. Turn on LAN Only Liveview on the printer.",
        .refused => "The camera of the printer refused the connection.",
        .bad_reply => "The printer answered with something that is not an RTSP stream.",
        .no_video => "The camera of the printer offers no H.264 video.",
        .too_big => "The camera of the printer sent an answer that is too long.",
    };
}

// ---- H.264 over RTP ----

pub const Frame = struct {
    /// Annex B: each NAL unit after 00 00 00 01.
    data: []u8,
    /// It has an IDR slice: a decoder can start here.
    key: bool,
    /// The RTP timestamp (90 kHz).
    timestamp: u32,
};

const start_code = [_]u8{ 0, 0, 0, 1 };

/// Turns RTP packets of H.264 (RFC 6184) into Annex B frames.
pub const Depacketizer = struct {
    sps: std.ArrayList(u8) = .empty,
    pps: std.ArrayList(u8) = .empty,
    /// The frame that comes in, in Annex B.
    au: std.ArrayList(u8) = .empty,
    au_ts: u32 = 0,
    open: bool = false,
    au_key: bool = false,
    au_sps: bool = false,
    au_pps: bool = false,
    /// A packet of the frame was lost or bad: the frame goes.
    damaged: bool = false,
    /// The NAL unit of FU-A fragments that comes in.
    fu: std.ArrayList(u8) = .empty,
    in_fu: bool = false,
    /// No frame out until a key frame.
    wait_key: bool = true,
    last_seq: ?u16 = null,
    frames: std.ArrayList(Frame) = .empty,
    /// The frames dropped, for a log.
    dropped: u32 = 0,

    pub fn deinit(d: *Depacketizer, gpa: Allocator) void {
        d.sps.deinit(gpa);
        d.pps.deinit(gpa);
        d.au.deinit(gpa);
        d.fu.deinit(gpa);
        for (d.frames.items) |f| gpa.free(f.data);
        d.frames.deinit(gpa);
    }

    /// A parameter set from the SDP or the stream.
    fn keepSet(d: *Depacketizer, gpa: Allocator, nal: []const u8) Allocator.Error!void {
        if (nal.len == 0 or nal.len > max_text) return;
        const list = switch (nal[0] & 0x1F) {
            7 => &d.sps,
            8 => &d.pps,
            else => return,
        };
        list.clearRetainingCapacity();
        try list.appendSlice(gpa, nal);
    }

    fn addNal(d: *Depacketizer, gpa: Allocator, nal: []const u8) Allocator.Error!void {
        if (nal.len == 0) return;
        switch (nal[0] & 0x1F) {
            5 => d.au_key = true,
            7 => {
                d.au_sps = true;
                try d.keepSet(gpa, nal);
            },
            8 => {
                d.au_pps = true;
                try d.keepSet(gpa, nal);
            },
            else => {},
        }
        if (d.au.items.len + start_code.len + nal.len > max_frame) {
            d.damaged = true;
            return;
        }
        try d.au.appendSlice(gpa, &start_code);
        try d.au.appendSlice(gpa, nal);
    }

    /// The frame that came in is whole: out, or dropped.
    fn finish(d: *Depacketizer, gpa: Allocator) Allocator.Error!void {
        defer {
            d.au.clearRetainingCapacity();
            d.open = false;
            d.au_key = false;
            d.au_sps = false;
            d.au_pps = false;
            d.damaged = false;
            d.in_fu = false;
            d.fu.clearRetainingCapacity();
        }
        if (!d.open or d.au.items.len == 0) return;
        if (d.in_fu) d.damaged = true;
        if (d.damaged or (d.wait_key and !d.au_key)) {
            d.dropped += 1;
            d.wait_key = true;
            return;
        }
        // Too many frames wait: the shell does not keep up. They go, and
        // the next one out is a key frame.
        if (d.frames.items.len >= max_frames) {
            for (d.frames.items) |f| gpa.free(f.data);
            d.dropped += @intCast(d.frames.items.len);
            d.frames.clearRetainingCapacity();
            if (!d.au_key) {
                d.dropped += 1;
                d.wait_key = true;
                return;
            }
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (d.au_key) {
            if (!d.au_sps and d.sps.items.len > 0) {
                try out.appendSlice(gpa, &start_code);
                try out.appendSlice(gpa, d.sps.items);
            }
            if (!d.au_pps and d.pps.items.len > 0) {
                try out.appendSlice(gpa, &start_code);
                try out.appendSlice(gpa, d.pps.items);
            }
        }
        try out.appendSlice(gpa, d.au.items);
        const data = try out.toOwnedSlice(gpa);
        errdefer gpa.free(data);
        try d.frames.append(gpa, .{ .data = data, .key = d.au_key, .timestamp = d.au_ts });
        d.wait_key = false;
    }

    /// One RTP packet (RFC 3550): a 12-byte header, CSRCs, an extension,
    /// the payload, and padding. A packet with a bad header is skipped;
    /// `payload_type` null takes any.
    pub fn packet(d: *Depacketizer, gpa: Allocator, p: []const u8, payload_type: ?u8) Allocator.Error!void {
        if (p.len < 12 or p[0] >> 6 != 2) return;
        const padding = p[0] & 0x20 != 0;
        const extension = p[0] & 0x10 != 0;
        const cc: usize = p[0] & 0x0F;
        const marker = p[1] & 0x80 != 0;
        const pt = p[1] & 0x7F;
        if (payload_type) |want| if (pt != want) return;
        const seq = std.mem.readInt(u16, p[2..4], .big);
        const ts = std.mem.readInt(u32, p[4..8], .big);
        var start: usize = 12 + 4 * cc;
        if (start > p.len) return;
        if (extension) {
            if (start + 4 > p.len) return;
            const words: usize = std.mem.readInt(u16, p[start + 2 ..][0..2], .big);
            start += 4 + 4 * words;
            if (start > p.len) return;
        }
        var end = p.len;
        if (padding) {
            const n: usize = p[p.len - 1];
            if (n == 0 or n > end - start) return;
            end -= n;
        }
        // A gap: the frame that comes in lost a packet, and so does the
        // frame of this packet when it is a new one.
        if (d.last_seq) |last| {
            if (seq != last +% 1) {
                if (d.open) {
                    d.damaged = true;
                    try d.finish(gpa);
                }
                d.damaged = true;
                d.wait_key = true;
            }
        }
        d.last_seq = seq;
        if (d.open and ts != d.au_ts) {
            const keep = d.damaged;
            d.damaged = false;
            try d.finish(gpa);
            d.damaged = keep;
        }
        d.open = true;
        d.au_ts = ts;
        try d.payload(gpa, p[start..end]);
        if (marker) try d.finish(gpa);
    }

    fn payload(d: *Depacketizer, gpa: Allocator, p: []const u8) Allocator.Error!void {
        if (p.len == 0) return;
        switch (p[0] & 0x1F) {
            1...23 => try d.addNal(gpa, p),
            // STAP-A: the NAL units, each after its u16 size.
            24 => {
                var i: usize = 1;
                while (i + 2 <= p.len) {
                    const n: usize = std.mem.readInt(u16, p[i..][0..2], .big);
                    i += 2;
                    if (n == 0 or n > p.len - i) {
                        d.damaged = true;
                        return;
                    }
                    try d.addNal(gpa, p[i .. i + n]);
                    i += n;
                }
            },
            // FU-A: the NAL header from the indicator and the FU header.
            28 => {
                if (p.len < 2) {
                    d.damaged = true;
                    return;
                }
                const first = p[1] & 0x80 != 0;
                const last = p[1] & 0x40 != 0;
                if (first) {
                    d.fu.clearRetainingCapacity();
                    try d.fu.append(gpa, (p[0] & 0xE0) | (p[1] & 0x1F));
                    d.in_fu = true;
                } else if (!d.in_fu) {
                    d.damaged = true;
                    return;
                }
                if (d.fu.items.len + p.len - 2 > max_frame) {
                    d.damaged = true;
                    d.in_fu = false;
                    d.fu.clearRetainingCapacity();
                    return;
                }
                try d.fu.appendSlice(gpa, p[2..]);
                if (last) {
                    d.in_fu = false;
                    try d.addNal(gpa, d.fu.items);
                    d.fu.clearRetainingCapacity();
                }
            },
            // STAP-B, MTAP, FU-B: not in packetization mode 1.
            else => {},
        }
    }
};

// ---- RTSP ----

const Auth = struct {
    digest: bool,
    realm: []u8,
    nonce: []u8,
    opaque_: []u8,
    qop: bool,
    nc: u32 = 0,

    fn deinit(a: *Auth, gpa: Allocator) void {
        gpa.free(a.realm);
        gpa.free(a.nonce);
        gpa.free(a.opaque_);
    }
};

const Step = enum { describe, setup, play, playing };

pub const Session = struct {
    gpa: Allocator,
    /// The url with no user or password in it.
    url: []u8,
    user: []u8,
    password: []u8,
    step: Step = .describe,
    state: State = .connecting,
    failure: Failure = .none,
    /// The status of the last answer.
    status: u16 = 0,
    cseq: u32 = 0,
    /// The request went again with a login after a 401.
    retried: bool = false,
    auth: ?Auth = null,
    /// The url of the session (Content-Base), and of the video track.
    base: []u8 = &.{},
    track: []u8 = &.{},
    session_id: []u8 = &.{},
    channel: u8 = 0,
    payload_type: ?u8 = null,
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// output gave the bytes of `out`: they go at the next call.
    given: bool = false,
    video: Depacketizer = .{},
    /// The frame that `nextFrame` gave, freed at the next call.
    last: ?Frame = null,

    /// A session for `url` (rtsps://host:322/streaming/live/1). Its first
    /// request (DESCRIBE) waits in `output`.
    pub fn init(gpa: Allocator, url: []const u8, user: []const u8, password: []const u8) Allocator.Error!Session {
        var s: Session = .{ .gpa = gpa, .url = &.{}, .user = &.{}, .password = &.{} };
        errdefer s.deinit();
        s.url = try gpa.dupe(u8, url);
        s.user = try gpa.dupe(u8, user);
        s.password = try gpa.dupe(u8, password);
        try s.send();
        return s;
    }

    pub fn deinit(s: *Session) void {
        const gpa = s.gpa;
        gpa.free(s.url);
        std.crypto.secureZero(u8, s.password);
        gpa.free(s.user);
        gpa.free(s.password);
        if (s.auth) |*a| a.deinit(gpa);
        gpa.free(s.base);
        gpa.free(s.track);
        gpa.free(s.session_id);
        s.in.deinit(gpa);
        s.out.deinit(gpa);
        s.video.deinit(gpa);
        if (s.last) |f| gpa.free(f.data);
    }

    /// The bytes to write now (empty: none). They stay valid until the
    /// next call of a function of the session.
    pub fn output(s: *Session) []const u8 {
        s.dropGiven();
        if (s.out.items.len == 0) return "";
        s.given = true;
        return s.out.items;
    }

    fn dropGiven(s: *Session) void {
        if (!s.given) return;
        s.out.clearRetainingCapacity();
        s.given = false;
    }

    fn fail(s: *Session, f: Failure) void {
        s.state = .failed;
        s.failure = f;
    }

    /// The url of the session for PLAY and the keep-alive.
    fn sessionUrl(s: *const Session) []const u8 {
        return if (s.base.len > 0) s.base else s.url;
    }

    fn send(s: *Session) Allocator.Error!void {
        switch (s.step) {
            .describe => try s.request("DESCRIBE", s.url, "Accept: application/sdp\r\n"),
            .setup => try s.request("SETUP", s.track, "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"),
            .play => {
                const extra = try std.fmt.allocPrint(s.gpa, "Session: {s}\r\nRange: npt=0.000-\r\n", .{s.session_id});
                defer s.gpa.free(extra);
                try s.request("PLAY", s.sessionUrl(), extra);
            },
            .playing => {},
        }
    }

    /// A GET_PARAMETER that keeps the session: send it within the timeout
    /// of the server (60 s by default), each 30 s for one.
    pub fn keepAlive(s: *Session) Allocator.Error!void {
        if (s.step != .playing or s.state != .playing) return;
        const extra = try std.fmt.allocPrint(s.gpa, "Session: {s}\r\n", .{s.session_id});
        defer s.gpa.free(extra);
        try s.request("GET_PARAMETER", s.sessionUrl(), extra);
    }

    /// TEARDOWN, to end the session before the socket closes.
    pub fn teardown(s: *Session) Allocator.Error!void {
        if (s.session_id.len == 0) return;
        const extra = try std.fmt.allocPrint(s.gpa, "Session: {s}\r\n", .{s.session_id});
        defer s.gpa.free(extra);
        try s.request("TEARDOWN", s.sessionUrl(), extra);
    }

    fn request(s: *Session, method: []const u8, uri: []const u8, extra: []const u8) Allocator.Error!void {
        s.dropGiven();
        const gpa = s.gpa;
        s.cseq += 1;
        var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &s.out);
        defer s.out = w.toArrayList();
        const ww = &w.writer;
        ww.print("{s} {s} RTSP/1.0\r\nCSeq: {d}\r\nUser-Agent: zslice\r\n", .{ method, uri, s.cseq }) catch return error.OutOfMemory;
        if (s.auth) |*a| try s.authorization(ww, a, method, uri);
        ww.writeAll(extra) catch return error.OutOfMemory;
        ww.writeAll("\r\n") catch return error.OutOfMemory;
    }

    fn authorization(s: *Session, w: *std.Io.Writer, a: *Auth, method: []const u8, uri: []const u8) Allocator.Error!void {
        if (!a.digest) {
            const plain = try std.fmt.allocPrint(s.gpa, "{s}:{s}", .{ s.user, s.password });
            defer {
                std.crypto.secureZero(u8, plain);
                s.gpa.free(plain);
            }
            const enc = try s.gpa.alloc(u8, b64.Encoder.calcSize(plain.len));
            defer {
                std.crypto.secureZero(u8, enc);
                s.gpa.free(enc);
            }
            _ = b64.Encoder.encode(enc, plain);
            w.print("Authorization: Basic {s}\r\n", .{enc}) catch return error.OutOfMemory;
            return;
        }
        a.nc += 1;
        var nc: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&nc, "{x:0>8}", .{a.nc}) catch unreachable;
        const cnonce = "0a4f113b";
        const r = digestResponse(s.user, a.realm, s.password, method, uri, a.nonce, if (a.qop) &nc else null, cnonce);
        w.print("Authorization: Digest username=\"{s}\", realm=\"{s}\", nonce=\"{s}\", uri=\"{s}\", response=\"{s}\"", .{ s.user, a.realm, a.nonce, uri, r }) catch return error.OutOfMemory;
        if (a.opaque_.len > 0) w.print(", opaque=\"{s}\"", .{a.opaque_}) catch return error.OutOfMemory;
        if (a.qop) w.print(", qop=auth, nc={s}, cnonce=\"{s}\"", .{ nc, cnonce }) catch return error.OutOfMemory;
        w.writeAll(", algorithm=MD5\r\n") catch return error.OutOfMemory;
    }

    /// The bytes that came from the server. After it: `output` (requests
    /// to write), `nextFrame` (video), and `state`.
    pub fn feed(s: *Session, bytes: []const u8) Allocator.Error!void {
        s.dropGiven();
        if (s.state == .failed) return;
        try s.in.appendSlice(s.gpa, bytes);
        var at: usize = 0;
        defer {
            const rest = s.in.items.len - at;
            std.mem.copyForwards(u8, s.in.items[0..rest], s.in.items[at..]);
            s.in.items.len = rest;
        }
        while (s.state != .failed and at < s.in.items.len) {
            const b = s.in.items[at..];
            if (b[0] == '$') {
                if (b.len < 4) return;
                const n: usize = std.mem.readInt(u16, b[2..4], .big);
                if (b.len < 4 + n) return;
                if (b[1] == s.channel and s.step == .playing) try s.video.packet(s.gpa, b[4 .. 4 + n], s.payload_type);
                at += 4 + n;
                continue;
            }
            // An answer: "RTSP/1.0 200 OK", headers, a blank line, a body.
            const prefix = "RTSP/";
            if (!std.mem.startsWith(u8, b, prefix[0..@min(prefix.len, b.len)])) {
                // Not an answer and not a packet: a byte out of step.
                if (s.step != .playing) return s.fail(.bad_reply);
                at += 1;
                continue;
            }
            const head_end = std.mem.indexOf(u8, b[0..@min(b.len, max_head)], "\r\n\r\n") orelse {
                if (b.len >= max_head) s.fail(.too_big);
                return;
            };
            const head = b[0..head_end];
            const body_len = blk: {
                const v = header(head, "Content-Length") orelse break :blk 0;
                const n = std.fmt.parseInt(usize, v, 10) catch return s.fail(.bad_reply);
                if (n > max_body) return s.fail(.too_big);
                break :blk n;
            };
            const total = head_end + 4 + body_len;
            if (b.len < total) return;
            try s.answer(head, b[head_end + 4 .. total]);
            at += total;
        }
    }

    fn answer(s: *Session, head: []const u8, body: []const u8) Allocator.Error!void {
        const gpa = s.gpa;
        // "RTSP/1.0 200 OK"
        const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
        var it = std.mem.tokenizeScalar(u8, head[0..line_end], ' ');
        _ = it.next();
        const code = std.fmt.parseInt(u16, it.next() orelse return s.fail(.bad_reply), 10) catch return s.fail(.bad_reply);
        s.status = code;
        if (s.step == .playing) return; // a keep-alive or a teardown
        if (code == 401) {
            if (s.retried) return s.fail(.auth);
            const a = try parseAuth(gpa, head) orelse return s.fail(.auth);
            if (s.auth) |*old| old.deinit(gpa);
            s.auth = a;
            s.retried = true;
            return s.send();
        }
        if (code < 200 or code >= 300) return s.fail(if (code == 404) .not_found else .refused);
        s.retried = false;
        switch (s.step) {
            .describe => {
                const base = header(head, "Content-Base") orelse header(head, "Content-Location") orelse s.url;
                if (base.len > max_text) return s.fail(.too_big);
                gpa.free(s.base);
                s.base = try gpa.dupe(u8, base);
                const sdp = try s.readSdp(body) orelse return s.fail(.no_video);
                gpa.free(s.track);
                s.track = sdp;
                s.step = .setup;
            },
            .setup => {
                const v = header(head, "Session") orelse return s.fail(.bad_reply);
                const id = std.mem.trim(u8, v[0 .. std.mem.indexOfScalar(u8, v, ';') orelse v.len], " ");
                if (id.len == 0 or id.len > max_text) return s.fail(.bad_reply);
                gpa.free(s.session_id);
                s.session_id = try gpa.dupe(u8, id);
                if (header(head, "Transport")) |t| if (std.mem.indexOf(u8, t, "interleaved=")) |i| {
                    const rest = t[i + "interleaved=".len ..];
                    const n = rest[0 .. std.mem.indexOfAny(u8, rest, "-;") orelse rest.len];
                    s.channel = std.fmt.parseInt(u8, n, 10) catch 0;
                };
                s.step = .play;
            },
            .play => {
                s.step = .playing;
                s.state = .playing;
                return;
            },
            .playing => return,
        }
        try s.send();
    }

    /// The url of the H.264 track of an SDP, in gpa, and its payload type
    /// and parameter sets; null with no H.264 video.
    fn readSdp(s: *Session, sdp: []const u8) Allocator.Error!?[]u8 {
        var video = false;
        var h264 = false;
        var pt: ?u8 = null;
        var control: []const u8 = "";
        var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "m=")) {
                // A second video track: the first H.264 one is enough.
                if (video and h264) break;
                video = std.mem.startsWith(u8, line, "m=video ");
                h264 = false;
                pt = null;
                control = "";
                if (video) {
                    var f = std.mem.tokenizeScalar(u8, line, ' ');
                    var last: []const u8 = "";
                    var k: usize = 0;
                    while (f.next()) |x| : (k += 1) {
                        if (k == 3) last = x;
                    }
                    pt = std.fmt.parseInt(u8, last, 10) catch null;
                }
                continue;
            }
            if (!video) continue;
            if (std.mem.startsWith(u8, line, "a=rtpmap:")) {
                var f = std.mem.tokenizeScalar(u8, line["a=rtpmap:".len..], ' ');
                const n = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
                const enc = f.next() orelse continue;
                if (std.ascii.startsWithIgnoreCase(enc, "H264/")) {
                    h264 = true;
                    pt = n;
                }
            } else if (std.mem.startsWith(u8, line, "a=control:")) {
                control = std.mem.trim(u8, line["a=control:".len..], " ");
            } else if (std.mem.startsWith(u8, line, "a=fmtp:")) {
                if (std.mem.indexOf(u8, line, "sprop-parameter-sets=")) |i| {
                    const rest = line[i + "sprop-parameter-sets=".len ..];
                    const v = rest[0 .. std.mem.indexOfAny(u8, rest, "; ") orelse rest.len];
                    var sets = std.mem.tokenizeScalar(u8, v, ',');
                    while (sets.next()) |set| {
                        var buf: [max_text]u8 = undefined;
                        const n = b64.Decoder.calcSizeForSlice(set) catch continue;
                        if (n > buf.len) continue;
                        b64.Decoder.decode(buf[0..n], set) catch continue;
                        try s.video.keepSet(s.gpa, buf[0..n]);
                    }
                }
            }
        }
        if (!(video and h264)) return null;
        s.payload_type = pt;
        if (control.len > max_text) return null;
        return try resolve(s.gpa, s.base, control);
    }

    /// The next frame (valid until the next call), or null.
    pub fn nextFrame(s: *Session) ?Frame {
        if (s.last) |f| s.gpa.free(f.data);
        s.last = null;
        if (s.video.frames.items.len == 0) return null;
        s.last = s.video.frames.orderedRemove(0);
        return s.last;
    }
};

/// The value of a header of an RTSP answer, or null. The name is case
/// insensitive.
fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// The url of a control attribute: absolute, the base itself ("*" or
/// none), or relative to the base.
fn resolve(gpa: Allocator, base: []const u8, control: []const u8) Allocator.Error![]u8 {
    if (std.ascii.startsWithIgnoreCase(control, "rtsp://") or std.ascii.startsWithIgnoreCase(control, "rtsps://")) return gpa.dupe(u8, control);
    if (control.len == 0 or std.mem.eql(u8, control, "*")) return gpa.dupe(u8, base);
    if (std.mem.endsWith(u8, base, "/")) return std.mem.concat(gpa, u8, &.{ base, control });
    return std.mem.concat(gpa, u8, &.{ base, "/", control });
}

/// The login that a 401 asks for: Digest when a WWW-Authenticate header
/// offers it, else Basic. null with no such header.
fn parseAuth(gpa: Allocator, head: []const u8) Allocator.Error!?Auth {
    var basic = false;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "WWW-Authenticate")) continue;
        const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.startsWithIgnoreCase(v, "Basic")) basic = true;
        if (!std.ascii.startsWithIgnoreCase(v, "Digest")) continue;
        const realm = param(v, "realm") orelse "";
        const nonce = param(v, "nonce") orelse continue;
        const opq = param(v, "opaque") orelse "";
        if (realm.len > max_text or nonce.len > max_text or opq.len > max_text) continue;
        const qop = if (param(v, "qop")) |q| std.mem.indexOf(u8, q, "auth") != null else false;
        const r = try gpa.dupe(u8, realm);
        errdefer gpa.free(r);
        const n = try gpa.dupe(u8, nonce);
        errdefer gpa.free(n);
        return .{ .digest = true, .realm = r, .nonce = n, .opaque_ = try gpa.dupe(u8, opq), .qop = qop };
    }
    if (!basic) return null;
    return .{ .digest = false, .realm = try gpa.alloc(u8, 0), .nonce = try gpa.alloc(u8, 0), .opaque_ = try gpa.alloc(u8, 0), .qop = false };
}

/// The value of name="value" (or name=value) in a header value.
fn param(v: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, v, i, name)) |at| {
        i = at + name.len;
        // A whole word: after the scheme, a space, or a comma.
        if (at > 0 and v[at - 1] != ' ' and v[at - 1] != ',') continue;
        var j = i;
        while (j < v.len and v[j] == ' ') j += 1;
        if (j >= v.len or v[j] != '=') continue;
        j += 1;
        while (j < v.len and v[j] == ' ') j += 1;
        if (j < v.len and v[j] == '"') {
            const end = std.mem.indexOfScalarPos(u8, v, j + 1, '"') orelse return null;
            return v[j + 1 .. end];
        }
        const end = std.mem.indexOfAnyPos(u8, v, j, ", ") orelse v.len;
        return v[j..end];
    }
    return null;
}

fn md5Hex(parts: []const []const u8) [32]u8 {
    var h = Md5.init(.{});
    for (parts, 0..) |p, k| {
        if (k > 0) h.update(":");
        h.update(p);
    }
    var d: [16]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

/// The response of a Digest login (RFC 2617, MD5). nc null: no qop.
fn digestResponse(user: []const u8, realm: []const u8, password: []const u8, method: []const u8, uri: []const u8, nonce: []const u8, nc: ?[]const u8, cnonce: []const u8) [32]u8 {
    const ha1 = md5Hex(&.{ user, realm, password });
    const ha2 = md5Hex(&.{ method, uri });
    if (nc) |n| return md5Hex(&.{ &ha1, nonce, n, cnonce, "auth", &ha2 });
    return md5Hex(&.{ &ha1, nonce, &ha2 });
}

// ---- tests ----

const testing = std.testing;

test "rtsp: the digest of RFC 2617" {
    const r = digestResponse("Mufasa", "testrealm@host.com", "Circle Of Life", "GET", "/dir/index.html", "dcd98b7102dd2f0e8b11d0f600bfb0c093", "00000001", "0a4f113b");
    try testing.expectEqualStrings("6629fae49393a05397450978507c4ef1", &r);
}

test "rtsp: header values and parameters" {
    const head = "RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nwww-authenticate: Digest realm=\"LIVE555\", nonce=\"abc\", qop=\"auth\"";
    try testing.expectEqualStrings("1", header(head, "cseq").?);
    try testing.expect(header(head, "Session") == null);
    var a = (try parseAuth(testing.allocator, head)).?;
    defer a.deinit(testing.allocator);
    try testing.expect(a.digest and a.qop);
    try testing.expectEqualStrings("LIVE555", a.realm);
    try testing.expectEqualStrings("abc", a.nonce);
    try testing.expectEqualStrings("x", param("Digest nonce=x, realm=y", "nonce").?);
    // "nonce" inside "cnonce" is not the nonce.
    try testing.expectEqualStrings("z", param("Digest cnonce=q, nonce=z", "nonce").?);
    const r = try resolve(testing.allocator, "rtsps://h:322/streaming/live/1/", "track1");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("rtsps://h:322/streaming/live/1/track1", r);
}

/// An RTP packet of H.264 in a buffer.
fn rtp(buf: []u8, seq: u16, ts: u32, marker: bool, payload: []const u8) []u8 {
    buf[0] = 0x80;
    buf[1] = 96 | @as(u8, if (marker) 0x80 else 0);
    std.mem.writeInt(u16, buf[2..4], seq, .big);
    std.mem.writeInt(u32, buf[4..8], ts, .big);
    std.mem.writeInt(u32, buf[8..12], 0x1234, .big);
    @memcpy(buf[12 .. 12 + payload.len], payload);
    return buf[0 .. 12 + payload.len];
}

const sps = [_]u8{ 0x67, 0x42, 0x00, 0x1f, 0xaa };
const pps = [_]u8{ 0x68, 0xce, 0x3c, 0x80 };

test "rtsp: STAP-A, FU-A, and a key frame with its parameter sets" {
    const gpa = testing.allocator;
    var d: Depacketizer = .{};
    defer d.deinit(gpa);
    var buf: [256]u8 = undefined;
    // A P frame before any key frame: dropped.
    try d.packet(gpa, rtp(&buf, 1, 100, true, &.{ 0x41, 1, 2 }), 96);
    try testing.expectEqual(@as(usize, 0), d.frames.items.len);
    // STAP-A with the SPS and the PPS, then an IDR in three fragments.
    var stap: [32]u8 = undefined;
    stap[0] = 0x78;
    std.mem.writeInt(u16, stap[1..3], sps.len, .big);
    @memcpy(stap[3 .. 3 + sps.len], &sps);
    std.mem.writeInt(u16, stap[3 + sps.len ..][0..2], pps.len, .big);
    @memcpy(stap[5 + sps.len .. 5 + sps.len + pps.len], &pps);
    try d.packet(gpa, rtp(&buf, 2, 200, false, stap[0 .. 5 + sps.len + pps.len]), 96);
    try d.packet(gpa, rtp(&buf, 3, 200, false, &.{ 0x7c, 0x85, 0xaa }), 96);
    try d.packet(gpa, rtp(&buf, 4, 200, false, &.{ 0x7c, 0x05, 0xbb }), 96);
    try d.packet(gpa, rtp(&buf, 5, 200, true, &.{ 0x7c, 0x45, 0xcc }), 96);
    try testing.expectEqual(@as(usize, 1), d.frames.items.len);
    const f = d.frames.items[0];
    try testing.expect(f.key);
    const want = [_]u8{ 0, 0, 0, 1 } ++ sps ++ [_]u8{ 0, 0, 0, 1 } ++ pps ++ [_]u8{ 0, 0, 0, 1, 0x65, 0xaa, 0xbb, 0xcc };
    try testing.expectEqualSlices(u8, &want, f.data);
    // A P frame now comes out.
    try d.packet(gpa, rtp(&buf, 6, 300, true, &.{ 0x41, 9 }), 96);
    try testing.expectEqual(@as(usize, 2), d.frames.items.len);
    try testing.expect(!d.frames.items[1].key);
    // A lost packet (7): the frame of 8 goes, and so do frames up to the
    // next key frame. A key frame with no SPS gets the kept one.
    try d.packet(gpa, rtp(&buf, 8, 400, true, &.{ 0x41, 9 }), 96);
    try d.packet(gpa, rtp(&buf, 9, 500, true, &.{ 0x41, 9 }), 96);
    try testing.expectEqual(@as(usize, 2), d.frames.items.len);
    try d.packet(gpa, rtp(&buf, 10, 600, true, &.{ 0x65, 7 }), 96);
    try testing.expectEqual(@as(usize, 3), d.frames.items.len);
    try testing.expect(std.mem.startsWith(u8, d.frames.items[2].data, &([_]u8{ 0, 0, 0, 1 } ++ sps)));
    // The P frame before the first key frame, and the two after the gap.
    try testing.expectEqual(@as(u32, 3), d.dropped);
}

test "rtsp: crafted packets do not break the depacketizer" {
    const gpa = testing.allocator;
    var d: Depacketizer = .{};
    defer d.deinit(gpa);
    var buf: [64]u8 = undefined;
    // Too short, a wrong version, CSRCs past the end, an extension past
    // the end, padding past the payload, a wrong payload type.
    try d.packet(gpa, &.{ 0x80, 96, 0, 1 }, 96);
    try d.packet(gpa, &([_]u8{0x40} ++ [_]u8{0} ** 12), 96);
    try d.packet(gpa, &([_]u8{0x8F} ++ [_]u8{0} ** 12), 96);
    var ext = [_]u8{ 0x90, 96, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0xFF, 0xFF };
    try d.packet(gpa, &ext, 96);
    var pad = [_]u8{ 0xA0, 96, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0x65, 200 };
    try d.packet(gpa, &pad, 96);
    try d.packet(gpa, rtp(&buf, 1, 1, true, &.{ 0x65, 1 }), 97);
    // STAP-A with a size past the end; an FU-A with no start; an FU-A of
    // one byte; an FU-A start that never ends before the marker.
    try d.packet(gpa, rtp(&buf, 2, 2, true, &.{ 0x78, 0xFF, 0xFF, 0x65 }), 96);
    try d.packet(gpa, rtp(&buf, 3, 3, true, &.{ 0x7c, 0x05, 1 }), 96);
    try d.packet(gpa, rtp(&buf, 4, 4, true, &.{0x7c}), 96);
    try d.packet(gpa, rtp(&buf, 5, 5, true, &.{ 0x7c, 0x85, 1 }), 96);
    try testing.expectEqual(@as(usize, 0), d.frames.items.len);
    // A good key frame still comes out after all that.
    try d.packet(gpa, rtp(&buf, 6, 6, true, &.{ 0x65, 1 }), 96);
    try testing.expectEqual(@as(usize, 1), d.frames.items.len);
}

test "rtsp: frames that wait are bounded" {
    const gpa = testing.allocator;
    var d: Depacketizer = .{};
    defer d.deinit(gpa);
    var buf: [64]u8 = undefined;
    var seq: u16 = 0;
    var k: u32 = 0;
    while (k < max_frames + 5) : (k += 1) {
        seq +%= 1;
        try d.packet(gpa, rtp(&buf, seq, k, true, if (k == 0) &.{ 0x65, 1 } else &.{ 0x41, 1 }), 96);
    }
    try testing.expect(d.frames.items.len <= max_frames);
}

/// A session that ran to PLAY, fed one byte at a time.
fn feedSlowly(s: *Session, bytes: []const u8) !void {
    for (bytes) |b| try s.feed(&.{b});
}

test "rtsp: a session with a Digest login, byte by byte" {
    const gpa = testing.allocator;
    var s = try Session.init(gpa, "rtsps://192.168.1.50:322/streaming/live/1", "bblp", "12345678");
    defer s.deinit();
    const d1 = s.output();
    try testing.expect(std.mem.startsWith(u8, d1, "DESCRIBE rtsps://192.168.1.50:322/streaming/live/1 RTSP/1.0\r\nCSeq: 1\r\n"));
    try testing.expectEqualStrings("", s.output());
    try feedSlowly(&s, "RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm=\"LIVE555 Streaming Media\", nonce=\"f00d\"\r\n\r\n");
    const d2 = s.output();
    try testing.expect(std.mem.indexOf(u8, d2, "CSeq: 2") != null);
    try testing.expect(std.mem.indexOf(u8, d2, "Authorization: Digest username=\"bblp\"") != null);
    // The access code is never in a request.
    try testing.expect(std.mem.indexOf(u8, d2, "12345678") == null);
    const sdp = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=live\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAH6o=,aM48gA==\r\na=control:track1\r\n";
    var ans: [512]u8 = undefined;
    const a2 = try std.fmt.bufPrint(&ans, "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Base: rtsps://192.168.1.50:322/streaming/live/1/\r\nContent-Type: application/sdp\r\nContent-Length: {d}\r\n\r\n{s}", .{ sdp.len, sdp });
    try feedSlowly(&s, a2);
    const d3 = s.output();
    try testing.expect(std.mem.startsWith(u8, d3, "SETUP rtsps://192.168.1.50:322/streaming/live/1/track1 RTSP/1.0\r\n"));
    try testing.expectEqualSlices(u8, &sps, s.video.sps.items);
    try testing.expectEqualSlices(u8, &pps, s.video.pps.items);
    try feedSlowly(&s, "RTSP/1.0 200 OK\r\nCSeq: 3\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nSession: 4F2A;timeout=65\r\n\r\n");
    const d4 = s.output();
    try testing.expect(std.mem.startsWith(u8, d4, "PLAY rtsps://192.168.1.50:322/streaming/live/1/ RTSP/1.0\r\n"));
    try testing.expect(std.mem.indexOf(u8, d4, "Session: 4F2A\r\n") != null);
    // The PLAY answer and the first packet in one read.
    var buf: [64]u8 = undefined;
    const p = rtp(&buf, 1, 9000, true, &.{ 0x65, 0x88 });
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, "RTSP/1.0 200 OK\r\nCSeq: 4\r\nSession: 4F2A\r\n\r\n");
    try all.appendSlice(gpa, &.{ '$', 0, 0, @intCast(p.len) });
    try all.appendSlice(gpa, p);
    // An RTCP packet on channel 1 is skipped.
    try all.appendSlice(gpa, &.{ '$', 1, 0, 2, 0x80, 0xC8 });
    try feedSlowly(&s, all.items);
    try testing.expectEqual(State.playing, s.state);
    const f = s.nextFrame().?;
    try testing.expect(f.key);
    try testing.expect(std.mem.endsWith(u8, f.data, &.{ 0, 0, 0, 1, 0x65, 0x88 }));
    try testing.expect(std.mem.startsWith(u8, f.data, &([_]u8{ 0, 0, 0, 1 } ++ sps)));
    try testing.expect(s.nextFrame() == null);
    try s.keepAlive();
    try testing.expect(std.mem.startsWith(u8, s.output(), "GET_PARAMETER "));
    try s.feed("RTSP/1.0 200 OK\r\nCSeq: 5\r\n\r\n");
    try testing.expectEqual(State.playing, s.state);
}

test "rtsp: a Basic login, a wrong code, and a missing stream" {
    const gpa = testing.allocator;
    {
        var s = try Session.init(gpa, "rtsps://h:322/streaming/live/1", "bblp", "code");
        defer s.deinit();
        _ = s.output();
        try s.feed("RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Basic realm=\"x\"\r\n\r\n");
        // base64 of "bblp:code".
        try testing.expect(std.mem.indexOf(u8, s.output(), "Authorization: Basic YmJscDpjb2Rl\r\n") != null);
        try s.feed("RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Basic realm=\"x\"\r\n\r\n");
        try testing.expectEqual(State.failed, s.state);
        try testing.expectEqual(Failure.auth, s.failure);
    }
    {
        var s = try Session.init(gpa, "rtsps://h:322/streaming/live/1", "bblp", "code");
        defer s.deinit();
        try s.feed("RTSP/1.0 404 Not Found\r\nCSeq: 1\r\n\r\n");
        try testing.expectEqual(Failure.not_found, s.failure);
    }
}

test "rtsp: crafted answers fail the session" {
    const gpa = testing.allocator;
    const cases = [_]struct { bytes: []const u8, want: Failure }{
        .{ .bytes = "HTTP/1.1 200 OK\r\n\r\n", .want = .bad_reply },
        .{ .bytes = "RTSP/1.0 abc\r\n\r\n", .want = .bad_reply },
        .{ .bytes = "RTSP/1.0 200 OK\r\nContent-Length: 99999999\r\n\r\n", .want = .too_big },
        .{ .bytes = "RTSP/1.0 200 OK\r\nContent-Length: -1\r\n\r\n", .want = .bad_reply },
        .{ .bytes = "RTSP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nv=0\n", .want = .no_video },
        .{ .bytes = "RTSP/1.0 401 Unauthorized\r\n\r\n", .want = .auth },
    };
    for (cases) |c| {
        var s = try Session.init(gpa, "rtsps://h/x", "u", "p");
        defer s.deinit();
        try s.feed(c.bytes);
        try testing.expectEqual(State.failed, s.state);
        try testing.expectEqual(c.want, s.failure);
    }
    // A header block with no end, over its bound.
    var s = try Session.init(gpa, "rtsps://h/x", "u", "p");
    defer s.deinit();
    try s.feed("RTSP/1.0 200 OK\r\n");
    const filler = [_]u8{'a'} ** 1024;
    var k: usize = 0;
    while (k < 20) : (k += 1) try s.feed(&filler);
    try testing.expectEqual(Failure.too_big, s.failure);
    try testing.expect(s.in.items.len <= max_head + 2 * filler.len);
}

test "rtsp: random bytes after PLAY keep the bounds" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var s = try Session.init(gpa, "rtsps://h/x", "u", "p");
    defer s.deinit();
    s.step = .playing;
    s.state = .playing;
    var buf: [2048]u8 = undefined;
    var k: usize = 0;
    while (k < 2000) : (k += 1) {
        const n = rand.intRangeAtMost(usize, 1, buf.len);
        rand.bytes(buf[0..n]);
        // Now and then a packet header, so the RTP code runs too.
        if (k % 3 == 0 and n > 16) {
            buf[0] = '$';
            buf[1] = 0;
            std.mem.writeInt(u16, buf[2..4], @intCast(n - 4), .big);
            buf[4] = 0x80;
            buf[5] = 96 | (buf[5] & 0x80);
        }
        try s.feed(buf[0..n]);
        while (s.nextFrame()) |f| try testing.expect(f.data.len <= max_frame + 2 * max_text + 8);
        try testing.expect(s.in.items.len <= 4 + 65535 + buf.len);
    }
}
