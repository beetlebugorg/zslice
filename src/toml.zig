//! A parser for the subset of TOML that zslice profiles use.
//!
//! Supported:
//!   # comments
//!   key = value             (bare keys: letters, digits, _ and -)
//!   [table]                 (one level)
//!   "basic strings" with \" \\ \n \t escapes
//!   'literal strings'
//!   """multi-line basic strings"""
//!   '''multi-line literal strings'''
//!   integers and floats (with an optional sign and exponent)
//!   true and false
//!
//! Not supported (the parser reports an error): arrays, inline tables,
//! dotted keys, dates, and nested tables. Profiles do not need them.
//!
//! The parser gives each value as text: the content of a string, or the
//! token of a number or a boolean. `Settings.set` then parses the text to
//! the type of the setting. The parser does not allocate: the strings point
//! into the input, except strings with escapes, which go in the arena.
//!
//! TOML: https://toml.io/en/v1.0.0 (see docs/references/).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { string, number, boolean };

pub const Entry = struct {
    /// The table, or "" for keys before the first table.
    table: []const u8,
    key: []const u8,
    value: []const u8,
    kind: Kind,
    line: usize,
};

pub const Error = error{ SyntaxError, OutOfMemory };

/// Where a syntax error is, for a message to the user.
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

/// Parses `text`. The entries point into `text` or into `arena`.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error![]Entry {
    var p: Parser = .{ .arena = arena, .text = text, .diag = diag };
    return p.run();
}

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    diag: *Diagnostic,
    pos: usize = 0,
    line: usize = 1,
    table: []const u8 = "",
    entries: std.ArrayList(Entry) = .empty,

    fn fail(p: *Parser, message: []const u8) Error {
        p.diag.* = .{ .line = p.line, .message = message };
        return error.SyntaxError;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn skipSpace(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            p.pos += 1;
        }
    }

    /// Skips spaces and a comment, then expects the end of the line.
    fn endLine(p: *Parser) Error!void {
        p.skipSpace();
        if (p.peek() == '#') {
            while (p.peek()) |c| {
                if (c == '\n') break;
                p.pos += 1;
            }
        }
        if (p.peek()) |c| {
            if (c == '\r') p.pos += 1;
            if (p.peek()) |d| {
                if (d != '\n') return p.fail("unexpected text after the value");
                p.pos += 1;
                p.line += 1;
            }
        }
    }

    fn run(p: *Parser) Error![]Entry {
        while (p.pos < p.text.len) {
            p.skipSpace();
            const c = p.peek() orelse break;
            switch (c) {
                '\n' => {
                    p.pos += 1;
                    p.line += 1;
                },
                '\r', '#' => try p.endLine(),
                '[' => try p.parseTable(),
                else => try p.parseKeyValue(),
            }
        }
        return p.entries.toOwnedSlice(p.arena);
    }

    fn isBare(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    fn parseKey(p: *Parser) Error![]const u8 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (!isBare(c)) break;
            p.pos += 1;
        }
        if (p.pos == start) return p.fail("expected a key");
        if (p.peek() == '.') return p.fail("dotted keys are not supported: use a [table]");
        return p.text[start..p.pos];
    }

    fn parseTable(p: *Parser) Error!void {
        p.pos += 1;
        if (p.peek() == '[') return p.fail("arrays of tables are not supported");
        p.skipSpace();
        p.table = try p.parseKey();
        p.skipSpace();
        if (p.peek() != ']') return p.fail("expected ] after the table name");
        p.pos += 1;
        try p.endLine();
    }

    fn parseKeyValue(p: *Parser) Error!void {
        const line = p.line;
        const key = try p.parseKey();
        p.skipSpace();
        if (p.peek() != '=') return p.fail("expected = after the key");
        p.pos += 1;
        p.skipSpace();
        const c = p.peek() orelse return p.fail("expected a value after =");
        var value: []const u8 = undefined;
        var kind: Kind = .string;
        if (c == '"' or c == '\'') {
            value = try p.parseString();
        } else if (c == '[' or c == '{') {
            return p.fail("arrays and inline tables are not supported");
        } else {
            const start = p.pos;
            while (p.peek()) |d| {
                if (d == ' ' or d == '\t' or d == '\n' or d == '\r' or d == '#') break;
                p.pos += 1;
            }
            value = p.text[start..p.pos];
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                kind = .boolean;
            } else if (isNumber(value)) {
                kind = .number;
            } else {
                return p.fail("a text value needs quotes");
            }
        }
        for (p.entries.items) |e| {
            if (std.mem.eql(u8, e.table, p.table) and std.mem.eql(u8, e.key, key)) return p.fail("the key is defined twice");
        }
        try p.entries.append(p.arena, .{ .table = p.table, .key = key, .value = value, .kind = kind, .line = line });
        try p.endLine();
    }

    fn isNumber(s: []const u8) bool {
        var t = s;
        if (t.len > 0 and (t[0] == '+' or t[0] == '-')) t = t[1..];
        if (t.len == 0 or !std.ascii.isDigit(t[0])) return false;
        _ = std.fmt.parseFloat(f64, std.mem.trimStart(u8, s, "+")) catch return false;
        return true;
    }

    fn parseString(p: *Parser) Error![]const u8 {
        const quote = p.text[p.pos];
        const triple = p.pos + 2 < p.text.len and p.text[p.pos + 1] == quote and p.text[p.pos + 2] == quote;
        if (triple) {
            p.pos += 3;
            // A newline right after the opening quotes is not part of the
            // string.
            if (p.peek() == '\r') p.pos += 1;
            if (p.peek() == '\n') {
                p.pos += 1;
                p.line += 1;
            }
        } else {
            p.pos += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        var escaped = false;
        const start = p.pos;
        while (true) {
            const c = p.peek() orelse return p.fail("the string has no end quote");
            if (c == quote) {
                if (!triple) break;
                if (p.pos + 2 < p.text.len and p.text[p.pos + 1] == quote and p.text[p.pos + 2] == quote) break;
            }
            if (c == '\n') {
                if (!triple) return p.fail("the string has no end quote on this line");
                p.line += 1;
            }
            if (c == '\\' and quote == '"') {
                if (!escaped) {
                    escaped = true;
                    try out.appendSlice(p.arena, p.text[start..p.pos]);
                }
                p.pos += 1;
                const e = p.peek() orelse return p.fail("the string has no end quote");
                const ch: u8 = switch (e) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => return p.fail("unknown escape in a string (use \\\\ for a backslash)"),
                };
                try out.append(p.arena, ch);
                p.pos += 1;
                continue;
            }
            if (escaped) try out.append(p.arena, c);
            p.pos += 1;
        }
        const raw = p.text[start..p.pos];
        p.pos += if (triple) 3 else 1;
        return if (escaped) out.items else raw;
    }
};

const testing = std.testing;

test "parse a profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\# A gray PLA
        \\extends = "acme-pla"
        \\name = 'Acme PLA Gray'
        \\nozzle_temp = 220   # warmer than the base
        \\retract_ratio = 0.8
        \\
        \\[project]
        \\ironing = true
        \\start = """
        \\G28
        \\M83 ; "relative"
        \\"""
        \\path = "C:\\profiles\n"
    ;
    var diag: Diagnostic = .{};
    const entries = try parse(arena.allocator(), text, &diag);
    try testing.expectEqual(@as(usize, 7), entries.len);
    try testing.expectEqualStrings("acme-pla", entries[0].value);
    try testing.expectEqualStrings("Acme PLA Gray", entries[1].value);
    try testing.expectEqual(Kind.number, entries[2].kind);
    try testing.expectEqualStrings("220", entries[2].value);
    try testing.expectEqualStrings("project", entries[4].table);
    try testing.expectEqual(Kind.boolean, entries[4].kind);
    try testing.expectEqualStrings("G28\nM83 ; \"relative\"\n", entries[5].value);
    try testing.expectEqual(@as(usize, 9), entries[5].line);
    try testing.expectEqualStrings("C:\\profiles\n", entries[6].value);
}

test "syntax errors have a line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "a = 1\nb = hello\n", &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "a = [1, 2]\n", &diag));
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "a.b = 1\n", &diag));
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "a = 1\na = 2\n", &diag));
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "a = \"open\n", &diag));
}
