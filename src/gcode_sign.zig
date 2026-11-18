//! Signed G-code: a slicer signs each file, and a printer checks the
//! signature before it queues the file.
//!
//! The signature is a comment on the last line of the file:
//!
//!     ; zslice-signature: ed25519 <key id> <base64 signature>
//!
//! The signature is an Ed25519 signature (RFC 8032) of the SHA-256 hash
//! (FIPS 180-4) of all bytes before that line. A printer with no check of
//! signatures reads a comment, so a signed file prints on any printer.
//!
//! The key id is the first 8 bytes of the SHA-256 hash of the 32 bytes of
//! the public key, in lowercase hex (16 characters). A printer finds the
//! public key of a file by its id.
//!
//! The key texts:
//!
//! - a public key: `ed25519 <base64 of the 32 bytes>`;
//! - a secret key: `zslice-secret-key ed25519 <base64 of the 32-byte seed>`.
//!
//! The base64 is the standard alphabet with padding (RFC 4648). The seed
//! comes from the random source of the shell (the OS), because the core
//! has no random source of its own.
//!
//! See REFERENCES.md: RFC 8032, FIPS 180-4, and RFC 4648.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.standard;

/// The start of the signature line.
pub const line_prefix = "; zslice-signature: ";
/// The name of the algorithm in the line and in the key texts.
pub const algorithm = "ed25519";
const secret_prefix = "zslice-secret-key ed25519 ";
const public_prefix = "ed25519 ";

pub const KeyId = [16]u8;
pub const Seed = [Ed25519.KeyPair.seed_length]u8;
pub const PublicKey = [Ed25519.PublicKey.encoded_length]u8;

/// The longest signature line, with no newline.
pub const max_line = line_prefix.len + algorithm.len + 1 + 16 + 1 + b64.Encoder.calcSize(Ed25519.Signature.encoded_length);

/// The result of a check.
pub const Result = enum(c_int) {
    /// A good signature of a trusted key.
    ok = 0,
    /// The file has no signature line.
    unsigned = 1,
    /// The key of the signature is not in the trusted list.
    unknown_key = 2,
    /// The signature line is malformed, or the signature does not match
    /// the file.
    bad = 3,
};

pub const Check = struct {
    result: Result,
    /// The key id of the signature line, or all zero bytes.
    key_id: KeyId = @splat(0),
};

/// The key id of a public key.
pub fn keyId(public: PublicKey) KeyId {
    var h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&public, &h, .{});
    return std.fmt.bytesToHex(h[0..8].*, .lower);
}

/// The secret key text of a seed.
pub fn secretText(seed: Seed) [secret_prefix.len + b64.Encoder.calcSize(32)]u8 {
    var out: [secret_prefix.len + b64.Encoder.calcSize(32)]u8 = undefined;
    @memcpy(out[0..secret_prefix.len], secret_prefix);
    _ = b64.Encoder.encode(out[secret_prefix.len..], &seed);
    return out;
}

/// The public key text of a public key.
pub fn publicText(public: PublicKey) [public_prefix.len + b64.Encoder.calcSize(32)]u8 {
    var out: [public_prefix.len + b64.Encoder.calcSize(32)]u8 = undefined;
    @memcpy(out[0..public_prefix.len], public_prefix);
    _ = b64.Encoder.encode(out[public_prefix.len..], &public);
    return out;
}

fn decode32(text: []const u8) ![32]u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if ((b64.Decoder.calcSizeForSlice(t) catch return error.InvalidValue) != 32) return error.InvalidValue;
    var out: [32]u8 = undefined;
    b64.Decoder.decode(&out, t) catch return error.InvalidValue;
    return out;
}

/// Reads a secret key text.
pub fn parseSecret(text: []const u8) !Ed25519.KeyPair {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, t, secret_prefix)) return error.InvalidValue;
    const seed = try decode32(t[secret_prefix.len..]);
    return Ed25519.KeyPair.generateDeterministic(seed) catch error.InvalidValue;
}

/// Reads a public key text.
pub fn parsePublic(text: []const u8) !PublicKey {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, t, public_prefix)) return error.InvalidValue;
    const k = try decode32(t[public_prefix.len..]);
    _ = Ed25519.PublicKey.fromBytes(k) catch return error.InvalidValue;
    return k;
}

/// A file split at its signature line.
pub const Split = struct {
    /// The bytes before the signature line (all bytes with no line).
    body: []const u8,
    /// The signature line with no newline, or null.
    line: ?[]const u8,
};

/// Finds the signature line: the last line of the file, before at most one
/// newline ("\n" or "\r\n").
pub fn split(gcode: []const u8) Split {
    var end = gcode.len;
    if (end > 0 and gcode[end - 1] == '\n') end -= 1;
    if (end > 0 and gcode[end - 1] == '\r') end -= 1;
    const start = if (std.mem.lastIndexOfScalar(u8, gcode[0..end], '\n')) |i| i + 1 else 0;
    const line = gcode[start..end];
    if (!std.mem.startsWith(u8, line, line_prefix)) return .{ .body = gcode, .line = null };
    return .{ .body = gcode[0..start], .line = line };
}

/// The SHA-256 hash of the bytes that a signature covers.
fn digest(body: []const u8, newline: bool) [Sha256.digest_length]u8 {
    var h = Sha256.init(.{});
    h.update(body);
    if (newline) h.update("\n");
    var d: [Sha256.digest_length]u8 = undefined;
    h.final(&d);
    return d;
}

/// The signature line of `body` (no newline) into `out`. The body must end
/// with a newline, or be empty.
pub fn signLine(kp: Ed25519.KeyPair, body: []const u8, out: *[max_line]u8) ![]const u8 {
    return signDigest(kp, digest(body, false), out);
}

fn signDigest(kp: Ed25519.KeyPair, d: [Sha256.digest_length]u8, out: *[max_line]u8) ![]const u8 {
    const sig = kp.sign(&d, null) catch return error.InvalidValue;
    const id = keyId(kp.public_key.toBytes());
    var sig_b64: [b64.Encoder.calcSize(64)]u8 = undefined;
    _ = b64.Encoder.encode(&sig_b64, &sig.toBytes());
    return std.fmt.bufPrint(out, line_prefix ++ algorithm ++ " {s} {s}", .{ &id, &sig_b64 }) catch unreachable;
}

/// Signs a G-code file: a copy of it with the signature line at the end.
/// An old signature line goes away first. A body with no newline at its
/// end gets one, so the signature line is a line of its own.
pub fn sign(gpa: std.mem.Allocator, kp: Ed25519.KeyPair, gcode: []const u8) ![]u8 {
    const body = split(gcode).body;
    const add_nl = body.len > 0 and body[body.len - 1] != '\n';
    var buf: [max_line]u8 = undefined;
    const line = try signDigest(kp, digest(body, add_nl), &buf);
    const n = body.len + @intFromBool(add_nl) + line.len + 1;
    const out = try gpa.alloc(u8, n);
    @memcpy(out[0..body.len], body);
    var i = body.len;
    if (add_nl) {
        out[i] = '\n';
        i += 1;
    }
    @memcpy(out[i..][0..line.len], line);
    out[n - 1] = '\n';
    return out;
}

/// The parts of a signature line.
const Line = struct {
    key_id: KeyId,
    sig: [64]u8,
};

fn parseLine(line: []const u8) ?Line {
    var it = std.mem.tokenizeAny(u8, line[line_prefix.len..], " \t\r");
    const alg = it.next() orelse return null;
    if (!std.mem.eql(u8, alg, algorithm)) return null;
    const id = it.next() orelse return null;
    if (id.len != 16) return null;
    for (id) |ch| if (!std.ascii.isHex(ch)) return null;
    const s = it.next() orelse return null;
    if (it.next() != null) return null;
    if ((b64.Decoder.calcSizeForSlice(s) catch return null) != 64) return null;
    var out: Line = .{ .key_id = undefined, .sig = undefined };
    b64.Decoder.decode(&out.sig, s) catch return null;
    out.key_id = std.ascii.lowerString(&out.key_id, id)[0..16].*;
    return out;
}

/// Checks the signature of a G-code file against the trusted public keys.
pub fn verify(gcode: []const u8, trusted: []const PublicKey) Check {
    const sp = split(gcode);
    const text = sp.line orelse return .{ .result = .unsigned };
    const ln = parseLine(text) orelse return .{ .result = .bad };
    const key = for (trusted) |k| {
        if (std.mem.eql(u8, &keyId(k), &ln.key_id)) break k;
    } else return .{ .result = .unknown_key, .key_id = ln.key_id };
    const pk = Ed25519.PublicKey.fromBytes(key) catch return .{ .result = .bad, .key_id = ln.key_id };
    const sig = Ed25519.Signature.fromBytes(ln.sig);
    const d = digest(sp.body, false);
    sig.verify(&d, pk) catch return .{ .result = .bad, .key_id = ln.key_id };
    return .{ .result = .ok, .key_id = ln.key_id };
}

// ---- tests ----

const testing = std.testing;

fn testKey(n: u8) Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(@splat(n)) catch unreachable;
}

test "a good signature checks" {
    const kp = testKey(1);
    const g = "G28\nG1 X10 Y10\n";
    const s = try sign(testing.allocator, kp, g);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.startsWith(u8, s, g));
    try testing.expect(std.mem.indexOf(u8, s, "\n; zslice-signature: ed25519 ") != null);
    try testing.expect(s[s.len - 1] == '\n');
    const c = verify(s, &.{ testKey(2).public_key.toBytes(), kp.public_key.toBytes() });
    try testing.expectEqual(Result.ok, c.result);
    try testing.expectEqualSlices(u8, &keyId(kp.public_key.toBytes()), &c.key_id);
}

test "one changed byte fails" {
    const kp = testKey(1);
    const s = try sign(testing.allocator, kp, "G28\nM104 S200\nG1 X10\n");
    defer testing.allocator.free(s);
    const trusted = [_]PublicKey{kp.public_key.toBytes()};
    for (0..split(s).body.len) |i| {
        const old = s[i];
        s[i] ^= 0x01;
        // A change of the last newline joins the signature line to the line
        // before it: the file is then unsigned.
        try testing.expect(verify(s, &trusted).result != .ok);
        s[i] = old;
    }
    try testing.expectEqual(Result.ok, verify(s, &trusted).result);
    // A changed signature fails too.
    const sig_at = s.len - 5;
    s[sig_at] = if (s[sig_at] == 'A') 'B' else 'A';
    try testing.expectEqual(Result.bad, verify(s, &trusted).result);
}

test "an unknown key fails" {
    const s = try sign(testing.allocator, testKey(1), "G28\n");
    defer testing.allocator.free(s);
    const c = verify(s, &.{testKey(2).public_key.toBytes()});
    try testing.expectEqual(Result.unknown_key, c.result);
    try testing.expectEqualSlices(u8, &keyId(testKey(1).public_key.toBytes()), &c.key_id);
    try testing.expectEqual(Result.unknown_key, verify(s, &.{}).result);
}

test "a file with no signature line is unsigned" {
    const k = [_]PublicKey{testKey(1).public_key.toBytes()};
    try testing.expectEqual(Result.unsigned, verify("G28\nG1 X1\n", &k).result);
    try testing.expectEqual(Result.unsigned, verify("", &k).result);
    // A signature line that is not the last line does not count.
    const s = try sign(testing.allocator, testKey(1), "G28\n");
    defer testing.allocator.free(s);
    const more = try std.mem.concat(testing.allocator, u8, &.{ s, "G1 X5\n" });
    defer testing.allocator.free(more);
    try testing.expectEqual(Result.unsigned, verify(more, &k).result);
}

test "a malformed line is bad" {
    const k = [_]PublicKey{testKey(1).public_key.toBytes()};
    try testing.expectEqual(Result.bad, verify("G28\n; zslice-signature: rsa 0011223344556677 AAAA\n", &k).result);
    try testing.expectEqual(Result.bad, verify("G28\n; zslice-signature: ed25519 00112233 AAAA\n", &k).result);
}

test "sign adds a newline, takes CRLF, and replaces an old signature" {
    const kp = testKey(3);
    const trusted = [_]PublicKey{kp.public_key.toBytes()};
    const a = try sign(testing.allocator, kp, "G28\nG1 X1");
    defer testing.allocator.free(a);
    try testing.expect(std.mem.startsWith(u8, a, "G28\nG1 X1\n; zslice-signature: "));
    try testing.expectEqual(Result.ok, verify(a, &trusted).result);
    // A CRLF file, and no newline after the signature line.
    const crlf = try sign(testing.allocator, kp, "G28\r\n");
    defer testing.allocator.free(crlf);
    try testing.expectEqual(Result.ok, verify(crlf[0 .. crlf.len - 1], &trusted).result);
    // A second signature replaces the first.
    const b = try sign(testing.allocator, testKey(4), a);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, b, line_prefix));
    try testing.expectEqual(Result.unknown_key, verify(b, &trusted).result);
    // An empty file.
    const e = try sign(testing.allocator, kp, "");
    defer testing.allocator.free(e);
    try testing.expectEqual(Result.ok, verify(e, &trusted).result);
}

test "the key texts" {
    const kp = testKey(5);
    const st = secretText(kp.secret_key.seed());
    const kp2 = try parseSecret(&st);
    try testing.expectEqualSlices(u8, &kp.public_key.toBytes(), &kp2.public_key.toBytes());
    const pt = publicText(kp.public_key.toBytes());
    try testing.expect(std.mem.startsWith(u8, &pt, "ed25519 "));
    try testing.expectEqualSlices(u8, &kp.public_key.toBytes(), &try parsePublic(&pt));
    try testing.expectError(error.InvalidValue, parsePublic("ed25519 AAAA"));
    try testing.expectError(error.InvalidValue, parseSecret(&pt));
}

test "the RFC 8032 test 1 key pair" {
    var seed: Seed = undefined;
    _ = try std.fmt.hexToBytes(&seed, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    var want: PublicKey = undefined;
    _ = try std.fmt.hexToBytes(&want, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    try testing.expectEqualSlices(u8, &want, &kp.public_key.toBytes());
    try testing.expectEqualStrings("ed25519 11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=", &publicText(want));
}
