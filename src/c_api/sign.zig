//! The C API of signed G-code (src/gcode_sign.zig): the key texts, the key
//! id, the signature of a file, and the check of a file. See zslice.h.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const gpa = c.gpa;
const sig = zs.gcode_sign;

fn bad() c_int {
    return @intFromEnum(Status.invalid_argument);
}

/// Copies `text` and a NUL byte into out[0..cap].
fn put(text: []const u8, out: ?[*]u8, cap: usize) c_int {
    const o = out orelse return bad();
    if (cap < text.len + 1) return @intFromEnum(Status.out_of_range);
    @memcpy(o[0..text.len], text);
    o[text.len] = 0;
    return 0;
}

fn span(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

/// The secret key text of a 32-byte seed from the random source of the OS.
export fn zs_sign_key_from_seed(seed: ?[*]const u8, seed_len: usize, out: ?[*]u8, cap: usize) c_int {
    const s = seed orelse return bad();
    if (seed_len != 32) return bad();
    _ = sig.parseSecret(&sig.secretText(s[0..32].*)) catch return bad();
    return put(&sig.secretText(s[0..32].*), out, cap);
}

/// The public key text of a secret key text.
export fn zs_sign_public_key(secret: ?[*:0]const u8, out: ?[*]u8, cap: usize) c_int {
    const kp = sig.parseSecret(span(secret) orelse return bad()) catch return @intFromEnum(Status.invalid_value);
    return put(&sig.publicText(kp.public_key.toBytes()), out, cap);
}

/// The key id (16 hex characters) of a public key text.
export fn zs_sign_key_id(public: ?[*:0]const u8, out: ?[*]u8, cap: usize) c_int {
    const k = sig.parsePublic(span(public) orelse return bad()) catch return @intFromEnum(Status.invalid_value);
    return put(&sig.keyId(k), out, cap);
}

/// A copy of the G-code with the signature line at its end. Free it with
/// zs_buffer_free.
export fn zs_sign_gcode(secret: ?[*:0]const u8, gcode: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const kp = sig.parseSecret(span(secret) orelse return bad()) catch return @intFromEnum(Status.invalid_value);
    const g: []const u8 = if (len == 0) "" else (gcode orelse return bad())[0..len];
    const o = out orelse return bad();
    const ol = out_len orelse return bad();
    const s = sig.sign(gpa, kp, g) catch |e| return c.status(e);
    o.* = s.ptr;
    ol.* = s.len;
    return 0;
}

/// Checks the signature of a G-code file. `trusted` is the public key
/// texts, one on each line. A line that does not read is skipped.
/// `result` gets a zs_signature_result. `key_id` (17 bytes or NULL) gets
/// the key id of the signature line, or "".
export fn zs_verify_gcode(gcode: ?[*]const u8, len: usize, trusted: ?[*:0]const u8, result: ?*c_int, key_id: ?[*]u8) c_int {
    const r = result orelse return bad();
    const g: []const u8 = if (len == 0) "" else (gcode orelse return bad())[0..len];
    var keys: std.ArrayList(sig.PublicKey) = .empty;
    defer keys.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, span(trusted) orelse "", '\n');
    while (it.next()) |line| {
        const k = sig.parsePublic(line) catch continue;
        keys.append(gpa, k) catch return @intFromEnum(Status.out_of_memory);
    }
    const ck = sig.verify(g, keys.items);
    r.* = @intFromEnum(ck.result);
    if (key_id) |o| {
        if (ck.key_id[0] == 0) o[0] = 0 else _ = put(&ck.key_id, o, 17);
    }
    return 0;
}

test "C API: sign and verify" {
    const seed: [32]u8 = @splat(7);
    var secret: [128]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zs_sign_key_from_seed(&seed, 32, &secret, secret.len));
    var public: [128]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zs_sign_public_key(@ptrCast(&secret), &public, public.len));
    var id: [17]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zs_sign_key_id(@ptrCast(&public), &id, id.len));
    const g = "G28\n";
    var out: ?[*]u8 = null;
    var n: usize = 0;
    try std.testing.expectEqual(@as(c_int, 0), zs_sign_gcode(@ptrCast(&secret), g, g.len, &out, &n));
    defer gpa.free(out.?[0..n]);
    var res: c_int = -1;
    var got: [17]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zs_verify_gcode(out, n, @ptrCast(&public), &res, &got));
    try std.testing.expectEqual(@as(c_int, 0), res);
    try std.testing.expectEqualStrings(std.mem.sliceTo(&id, 0), std.mem.sliceTo(&got, 0));
    try std.testing.expectEqual(@as(c_int, 0), zs_verify_gcode(g, g.len, @ptrCast(&public), &res, &got));
    try std.testing.expectEqual(@as(c_int, 1), res);
    try std.testing.expectEqual(@as(u8, 0), got[0]);
    try std.testing.expectEqual(@as(c_int, 0), zs_verify_gcode(out, n, "", &res, null));
    try std.testing.expectEqual(@as(c_int, 2), res);
}
