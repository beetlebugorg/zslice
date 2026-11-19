//! Bambu Lab printers in LAN mode: the file that they print, and the
//! messages that start a print and ask for the status.
//!
//! A shell sends a print in three steps (the network is the shell's work):
//!
//! 1. It uploads the file of `gcode3mf` over FTPS: implicit TLS on port
//!    990, the user "bblp", the access code of the printer (on its screen)
//!    as the password, to the root folder, with a name that ends in
//!    ".gcode.3mf".
//! 2. It connects to the MQTT broker of the printer: TLS on port 8883, the
//!    same user and password, and subscribes to "device/<serial>/report".
//! 3. After the user confirms that the plate is clear (a fresh click; never
//!    a timer or a retry), it publishes `startMessage` to
//!    "device/<serial>/request". `pushAllMessage` asks for the full status,
//!    and each report gives the state, the layer, and the time left.
//!
//! The printer reads the G-code of plate 1 (Metadata/plate_1.gcode) and its
//! MD5 (Metadata/plate_1.gcode.md5) from the 3MF file. The model part of
//! the file is empty: the printer prints the G-code.
//!
//! The file layout and the messages follow the public documents of the
//! LAN mode and the open source tools for it (see REFERENCES.md). No code
//! comes from them.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zipfile = @import("zipfile.zig");

/// A .gcode.3mf file with the G-code as plate 1, in gpa.
pub fn gcode3mf(gpa: Allocator, gcode: []const u8, title: []const u8) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const md5 = try a.dupe(u8, &gcodeMd5(gcode));
    const types =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/><Default Extension="gcode" ContentType="text/x.gcode"/><Default Extension="png" ContentType="image/png"/></Types>
        \\
    ;
    const rels =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        \\
    ;
    const model = try std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        \\ <metadata name="Application">zslice</metadata>
        \\ <metadata name="Title">{s}</metadata>
        \\ <resources/>
        \\ <build/>
        \\</model>
        \\
    , .{title});
    const settings =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<config>
        \\  <plate>
        \\    <metadata key="plater_id" value="1"/>
        \\    <metadata key="gcode_file" value="Metadata/plate_1.gcode"/>
        \\  </plate>
        \\</config>
        \\
    ;
    const entries = [_]zipfile.Entry{
        .{ .name = "[Content_Types].xml", .data = @constCast(types) },
        .{ .name = "_rels/.rels", .data = @constCast(rels) },
        .{ .name = "3D/3dmodel.model", .data = model },
        .{ .name = "Metadata/model_settings.config", .data = @constCast(settings) },
        .{ .name = "Metadata/plate_1.gcode", .data = @constCast(gcode) },
        .{ .name = "Metadata/plate_1.gcode.md5", .data = md5 },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try zipfile.write(gpa, &out.writer, &entries);
    return out.toOwnedSlice();
}

pub const Start = struct {
    /// The name of the file on the printer ("part.gcode.3mf").
    file: []const u8,
    /// The name of the print on the screen of the printer.
    title: []const u8,
    /// Level the bed before the print.
    bed_leveling: bool = true,
    /// Use the AMS (the filament changer), slot 0.
    use_ams: bool = false,
    timelapse: bool = false,
    /// The MD5 of plate_1.gcode (32 hex digits; `gcodeMd5`), or "". Some
    /// firmware checks it.
    md5: []const u8 = "",
    /// The url form "ftp://<file>" (P1 and A1, reported), in place of
    /// "file:///sdcard/<file>" (X1).
    ftp_url: bool = false,
};

/// The MD5 of the G-code in upper case hex, as the .md5 entry of the file.
pub fn gcodeMd5(gcode: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(gcode, &digest, .{});
    return std.fmt.bytesToHex(digest, .upper);
}

/// The MQTT message that starts the print of a file on the printer. Send
/// it only after a fresh confirmation of the user that the plate is clear.
pub fn startMessage(gpa: Allocator, s: Start) Allocator.Error![]u8 {
    const Msg = struct {
        print: struct {
            sequence_id: []const u8 = "0",
            command: []const u8 = "project_file",
            param: []const u8 = "Metadata/plate_1.gcode",
            project_id: []const u8 = "0",
            profile_id: []const u8 = "0",
            task_id: []const u8 = "0",
            subtask_id: []const u8 = "0",
            subtask_name: []const u8,
            url: []const u8,
            md5: []const u8 = "",
            timelapse: bool,
            bed_type: []const u8 = "auto",
            bed_levelling: bool,
            flow_cali: bool = false,
            vibration_cali: bool = false,
            layer_inspect: bool = false,
            use_ams: bool,
            ams_mapping: []const i32 = &.{0},
        },
    };
    const url = if (s.ftp_url) try std.fmt.allocPrint(gpa, "ftp://{s}", .{s.file}) else try std.fmt.allocPrint(gpa, "file:///sdcard/{s}", .{s.file});
    defer gpa.free(url);
    return std.json.Stringify.valueAlloc(gpa, Msg{ .print = .{
        .subtask_name = s.title,
        .url = url,
        .md5 = s.md5,
        .timelapse = s.timelapse,
        .bed_levelling = s.bed_leveling,
        .use_ams = s.use_ams,
    } }, .{});
}

/// The MQTT message that asks the printer for its full status.
pub const push_all_message = "{\"pushing\":{\"sequence_id\":\"0\",\"command\":\"pushall\"}}";

/// The camera of a Bambu Lab printer in LAN mode. Both kinds use TLS with
/// the self-signed certificate of the printer, the user "bblp", and the
/// access code.
pub const CameraKind = enum(u8) {
    /// The model is not known: try `rtsps`, then `jpeg`.
    unknown = 0,
    /// RTSP over TLS on port 322, H.264 video, at
    /// rtsps://bblp:<code>@<address>:322/streaming/live/1. The X1 series,
    /// the H2 series, the P2S, and the X2D. The printer must have "LAN
    /// Only Liveview" on.
    rtsps = 1,
    /// JPEG frames over TLS on port 6000 (`jpegAuth`): the P1 and A1
    /// series.
    jpeg = 2,
};

/// The camera kind of a printer of the library (its id, for example
/// "bambu-lab-x2d"), from the open source LAN tools (see REFERENCES.md).
pub fn cameraOf(model_id: []const u8) CameraKind {
    const jpeg = [_][]const u8{ "bambu-lab-a1", "bambu-lab-a1-mini", "bambu-lab-p1p", "bambu-lab-p1s" };
    for (jpeg) |m| if (std.mem.eql(u8, model_id, m)) return .jpeg;
    const rtsps = [_][]const u8{ "bambu-lab-x1", "bambu-lab-x1-carbon", "bambu-lab-x1e", "bambu-lab-x2d", "bambu-lab-p2s", "bambu-lab-h2d", "bambu-lab-h2d-pro", "bambu-lab-h2s", "bambu-lab-h2c" };
    for (rtsps) |m| if (std.mem.eql(u8, model_id, m)) return .rtsps;
    return .unknown;
}

/// The port and the path of the camera.
pub const rtsps_port = 322;
pub const rtsps_path = "/streaming/live/1";
pub const jpeg_port = 6000;

/// The 80 bytes that open the JPEG stream of port 6000: four little endian
/// u32 (0x40, 0x3000, 0, 0), then the user and the access code, each in 32
/// bytes with zeros after it. After them, the printer sends each frame as a
/// 16-byte header (the JPEG size as a little endian u32 first) and the
/// JPEG.
pub fn jpegAuth(code: []const u8) [80]u8 {
    var out = [_]u8{0} ** 80;
    std.mem.writeInt(u32, out[0..4], 0x40, .little);
    std.mem.writeInt(u32, out[4..8], 0x3000, .little);
    @memcpy(out[16..20], "bblp");
    const n = @min(code.len, 32);
    @memcpy(out[48..][0..n], code[0..n]);
    return out;
}

/// Collects the bytes of the JPEG stream of port 6000 and gives back each
/// whole frame: a 16-byte header (the size as a little endian u32 first),
/// then the JPEG. The slice of a frame stays valid until the next call.
pub const JpegReader = struct {
    buf: std.ArrayList(u8) = .empty,
    used: usize = 0,

    pub fn deinit(r: *JpegReader, gpa: Allocator) void {
        r.buf.deinit(gpa);
    }

    fn drop(r: *JpegReader) void {
        if (r.used == 0) return;
        const rest = r.buf.items.len - r.used;
        std.mem.copyForwards(u8, r.buf.items[0..rest], r.buf.items[r.used..]);
        r.buf.items.len = rest;
        r.used = 0;
    }

    pub fn feed(r: *JpegReader, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        r.drop();
        try r.buf.appendSlice(gpa, bytes);
    }

    /// The next whole JPEG, or null when more bytes must come.
    /// error.BadFrame: a size of 0 or over 16 MiB, or no JPEG start.
    pub fn next(r: *JpegReader) error{BadFrame}!?[]const u8 {
        r.drop();
        const b = r.buf.items;
        if (b.len < 16) return null;
        const n = std.mem.readInt(u32, b[0..4], .little);
        if (n < 4 or n > 16 * 1024 * 1024) return error.BadFrame;
        if (b.len < 16 + n) return null;
        const jpeg = b[16 .. 16 + n];
        if (jpeg[0] != 0xFF or jpeg[1] != 0xD8) return error.BadFrame;
        r.used = 16 + n;
        return jpeg;
    }
};

test "bambu: the frames of the JPEG stream" {
    const gpa = std.testing.allocator;
    var r: JpegReader = .{};
    defer r.deinit(gpa);
    const jpeg = [_]u8{ 0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9 };
    var head = [_]u8{0} ** 16;
    std.mem.writeInt(u32, head[0..4], jpeg.len, .little);
    try r.feed(gpa, &head);
    try std.testing.expect((try r.next()) == null);
    try r.feed(gpa, jpeg[0..3]);
    try std.testing.expect((try r.next()) == null);
    try r.feed(gpa, jpeg[3..]);
    try std.testing.expectEqualSlices(u8, &jpeg, (try r.next()).?);
    try std.testing.expect((try r.next()) == null);
    try r.feed(gpa, &([_]u8{0} ** 16));
    try std.testing.expectError(error.BadFrame, r.next());
}

test "bambu: the camera of each model" {
    try std.testing.expectEqual(CameraKind.rtsps, cameraOf("bambu-lab-x2d"));
    try std.testing.expectEqual(CameraKind.jpeg, cameraOf("bambu-lab-p1s"));
    try std.testing.expectEqual(CameraKind.unknown, cameraOf("prusa-mk4"));
    const a = jpegAuth("12345678");
    try std.testing.expectEqual(@as(u32, 0x3000), std.mem.readInt(u32, a[4..8], .little));
    try std.testing.expectEqualStrings("bblp", a[16..20]);
    try std.testing.expectEqualStrings("12345678", a[48..56]);
    try std.testing.expectEqual(@as(u8, 0), a[56]);
}

/// The MQTT topics of a printer.
pub fn reportTopic(gpa: Allocator, serial: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "device/{s}/report", .{serial});
}

pub fn requestTopic(gpa: Allocator, serial: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "device/{s}/request", .{serial});
}

const testing = std.testing;

test "bambu: the file has the G-code and its MD5" {
    const gpa = testing.allocator;
    const gcode = "G28\nG1 X10 Y10 E1\n";
    const bytes = try gcode3mf(gpa, gcode, "Benchy");
    defer gpa.free(bytes);
    const list = try zipfile.readAll(gpa, bytes);
    defer zipfile.freeAll(gpa, list);
    var found_gcode = false;
    var found_md5 = false;
    for (list) |e| {
        if (std.mem.eql(u8, e.name, "Metadata/plate_1.gcode")) {
            try testing.expectEqualStrings(gcode, e.data);
            found_gcode = true;
        }
        if (std.mem.eql(u8, e.name, "Metadata/plate_1.gcode.md5")) {
            try testing.expectEqual(@as(usize, 32), e.data.len);
            found_md5 = true;
        }
    }
    try testing.expect(found_gcode and found_md5);
}

test "bambu: the start message" {
    const gpa = testing.allocator;
    const m = try startMessage(gpa, .{ .file = "benchy.gcode.3mf", .title = "Benchy" });
    defer gpa.free(m);
    try testing.expect(std.mem.indexOf(u8, m, "\"command\":\"project_file\"") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"url\":\"file:///sdcard/benchy.gcode.3mf\"") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"param\":\"Metadata/plate_1.gcode\"") != null);
    const md5 = gcodeMd5("G28\n");
    const m2 = try startMessage(gpa, .{ .file = "a.gcode.3mf", .title = "A", .md5 = &md5, .ftp_url = true });
    defer gpa.free(m2);
    try testing.expect(std.mem.indexOf(u8, m2, "\"url\":\"ftp://a.gcode.3mf\"") != null);
    try testing.expect(std.mem.indexOf(u8, m2, &md5) != null);
}
