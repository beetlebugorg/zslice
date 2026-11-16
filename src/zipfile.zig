//! A small zip reader and writer, in memory, for 3MF files.
//!
//! A zip file is a list of entries (a local header, the name, and the
//! data, stored or deflated), then a central directory (one record for each
//! entry, with the offset of its local header), then an end record with
//! the offset of the central directory. The reader starts at the end
//! record. The writer deflates each entry. The reader also reads the zip64
//! records that some writers use for small files too; the writer does not
//! write them (no 3MF of zslice is 4 GB). Format: PKWARE APPNOTE.TXT (see REFERENCES.md); the header
//! structs and deflate come from the Zig standard library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zip = std.zip;
const flate = std.compress.flate;

pub const Error = error{ NotZip, Unsupported, Corrupt } || Allocator.Error;

pub const Entry = struct {
    name: []const u8,
    data: []u8,
};

/// All entries of a zip file. Free each name and data with `gpa`.
pub fn readAll(gpa: Allocator, bytes: []const u8) Error![]Entry {
    const end_size = @sizeOf(zip.EndRecord);
    if (bytes.len < end_size) return error.NotZip;
    // The end record is in the last 64 kB (a comment can follow it).
    var pos: usize = bytes.len - end_size;
    const stop = if (bytes.len > end_size + 65535) bytes.len - end_size - 65535 else 0;
    const end: zip.EndRecord = while (true) {
        if (std.mem.eql(u8, bytes[pos..][0..4], &zip.end_record_sig)) {
            break std.mem.bytesToValue(zip.EndRecord, bytes[pos..][0..end_size]);
        }
        if (pos == stop) return error.NotZip;
        pos -= 1;
    };
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }
    var cd: usize = end.central_directory_offset;
    var count: u64 = end.record_count_total;
    if (end.central_directory_offset == 0xffffffff or end.record_count_total == 0xffff) {
        // Zip64: a locator before the end record gives the zip64 end record.
        const ls = @sizeOf(zip.EndLocator64);
        if (pos < ls) return error.Corrupt;
        const loc = std.mem.bytesToValue(zip.EndLocator64, bytes[pos - ls ..][0..ls]);
        if (!std.mem.eql(u8, &loc.signature, &zip.end_locator64_sig)) return error.Corrupt;
        const es = @sizeOf(zip.EndRecord64);
        if (loc.record_file_offset + es > bytes.len) return error.Corrupt;
        const e64 = std.mem.bytesToValue(zip.EndRecord64, bytes[@intCast(loc.record_file_offset)..][0..es]);
        if (!std.mem.eql(u8, &e64.signature, &zip.end_record64_sig)) return error.Corrupt;
        if (e64.central_directory_offset > bytes.len) return error.Corrupt;
        cd = @intCast(e64.central_directory_offset);
        count = e64.record_count_total;
    }
    if (count > bytes.len) return error.Corrupt;
    for (0..@as(usize, @intCast(count))) |_| {
        const hs = @sizeOf(zip.CentralDirectoryFileHeader);
        if (cd + hs > bytes.len) return error.Corrupt;
        const h = std.mem.bytesToValue(zip.CentralDirectoryFileHeader, bytes[cd..][0..hs]);
        if (!std.mem.eql(u8, &h.signature, &zip.central_file_header_sig)) return error.Corrupt;
        if (cd + hs + h.filename_len > bytes.len) return error.Corrupt;
        const name = bytes[cd + hs ..][0..h.filename_len];
        if (cd + hs + h.filename_len + h.extra_len > bytes.len) return error.Corrupt;
        const extra = bytes[cd + hs + h.filename_len ..][0..h.extra_len];
        cd += hs + h.filename_len + h.extra_len + h.comment_len;
        var size: u64 = h.uncompressed_size;
        var csize: u64 = h.compressed_size;
        var offset: u64 = h.local_file_header_offset;
        // The zip64 extra field (id 1) has the 8-byte values of the fields
        // that are 0xffffffff, in this order.
        var x: usize = 0;
        while (x + 4 <= extra.len) {
            const id = std.mem.readInt(u16, extra[x..][0..2], .little);
            const len = std.mem.readInt(u16, extra[x + 2 ..][0..2], .little);
            if (x + 4 + len > extra.len) break;
            if (id == 1) {
                var f = extra[x + 4 ..][0..len];
                inline for (.{ &size, &csize, &offset }) |v| {
                    if (v.* == 0xffffffff and f.len >= 8) {
                        v.* = std.mem.readInt(u64, f[0..8], .little);
                        f = f[8..];
                    }
                }
            }
            x += 4 + len;
        }
        if (name.len > 0 and name[name.len - 1] == '/') continue; // a folder
        // The data starts after the local header, its name, and its extra.
        const ls = @sizeOf(zip.LocalFileHeader);
        if (offset > bytes.len or csize > bytes.len or size > 1 << 32) return error.Corrupt;
        const lo: usize = @intCast(offset);
        if (lo + ls > bytes.len) return error.Corrupt;
        const l = std.mem.bytesToValue(zip.LocalFileHeader, bytes[lo..][0..ls]);
        const start = lo + ls + l.filename_len + l.extra_len;
        if (start + csize > bytes.len) return error.Corrupt;
        const raw = bytes[start..][0..@intCast(csize)];
        const data = switch (h.compression_method) {
            .store => try gpa.dupe(u8, raw),
            .deflate => try inflate(gpa, raw, @intCast(size)),
            else => return error.Unsupported,
        };
        errdefer gpa.free(data);
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        try entries.append(gpa, .{ .name = n, .data = data });
    }
    return entries.toOwnedSlice(gpa);
}

pub fn freeAll(gpa: Allocator, entries: []Entry) void {
    for (entries) |e| {
        gpa.free(e.name);
        gpa.free(e.data);
    }
    gpa.free(entries);
}

fn inflate(gpa: Allocator, raw: []const u8, size: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(raw);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var d: flate.Decompress = .init(&in, .raw, window);
    return d.reader.allocRemaining(gpa, .limited(size + 1)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
}

/// Writes a zip file with the entries, deflated.
pub fn write(gpa: Allocator, out: *std.Io.Writer, entries: []const Entry) (Allocator.Error || std.Io.Writer.Error)!void {
    const Central = struct { h: zip.CentralDirectoryFileHeader, name: []const u8 };
    var central: std.ArrayList(Central) = .empty;
    defer central.deinit(gpa);
    var offset: u32 = 0;
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    for (entries) |e| {
        // The compressor needs a buffer of more than 8 bytes to start.
        var packed_data = try std.Io.Writer.Allocating.initCapacity(gpa, @max(64, e.data.len / 2));
        defer packed_data.deinit();
        var c = try flate.Compress.init(&packed_data.writer, window, .raw, .level_6);
        try c.writer.writeAll(e.data);
        try c.finish();
        const comp = packed_data.written();
        const crc = std.hash.Crc32.hash(e.data);
        const flags: @FieldType(zip.LocalFileHeader, "flags") = @bitCast(@as(u16, 0));
        const local: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = flags,
            .compression_method = .deflate,
            .last_modification_time = 0,
            .last_modification_date = (1 << 5) | 1, // 1980-01-01
            .crc32 = crc,
            .compressed_size = @intCast(comp.len),
            .uncompressed_size = @intCast(e.data.len),
            .filename_len = @intCast(e.name.len),
            .extra_len = 0,
        };
        try out.writeAll(std.mem.asBytes(&local));
        try out.writeAll(e.name);
        try out.writeAll(comp);
        try central.append(gpa, .{ .name = e.name, .h = .{
            .signature = zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = flags,
            .compression_method = .deflate,
            .last_modification_time = 0,
            .last_modification_date = (1 << 5) | 1,
            .crc32 = crc,
            .compressed_size = @intCast(comp.len),
            .uncompressed_size = @intCast(e.data.len),
            .filename_len = @intCast(e.name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = offset,
        } });
        offset += @intCast(@sizeOf(zip.LocalFileHeader) + e.name.len + comp.len);
    }
    const cd_start = offset;
    for (central.items) |c| {
        try out.writeAll(std.mem.asBytes(&c.h));
        try out.writeAll(c.name);
        offset += @intCast(@sizeOf(zip.CentralDirectoryFileHeader) + c.name.len);
    }
    const end: zip.EndRecord = .{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(entries.len),
        .record_count_total = @intCast(entries.len),
        .central_directory_size = offset - cd_start,
        .central_directory_offset = cd_start,
        .comment_len = 0,
    };
    try out.writeAll(std.mem.asBytes(&end));
}

test "zip: write and read back" {
    const gpa = std.testing.allocator;
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i % 7 + 'a');
    const entries = [_]Entry{
        .{ .name = "a.txt", .data = @constCast("hello") },
        .{ .name = "dir/b.bin", .data = &big },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &entries);
    // Deflate makes the repeated data small.
    try std.testing.expect(out.written().len < 2000);
    const back = try readAll(gpa, out.written());
    defer freeAll(gpa, back);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("a.txt", back[0].name);
    try std.testing.expectEqualStrings("hello", back[0].data);
    try std.testing.expectEqualSlices(u8, &big, back[1].data);
    try std.testing.expectError(error.NotZip, readAll(gpa, "not a zip file at all"));
}
