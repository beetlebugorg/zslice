//! A reader for the YAML of printdeck.yml files (project.zig). It reads the
//! subset that these files use:
//!
//! - block maps (`key: value`) and block lists (`- item`), also a list at
//!   the indent of its key, and a map that starts on the line of its `-`;
//! - flow lists (`[a, b]`) and flow maps (`{a: 1, b: 2}`), also over more
//!   than one line;
//! - plain, 'single', and "double" quoted scalars, and plain scalars over
//!   more than one line;
//! - block scalars: folded (`>`, `>-`, `>+`) and literal (`|`, `|-`, `|+`);
//! - anchors (`&name`), aliases (`*name`), and the merge key (`<<: *name`);
//! - comments, and the `---` and `...` markers of one document.
//!
//! All scalars are text: the reader of the value converts them (a count,
//! true or false). Tags, complex keys, and more than one document are not
//! in the subset, and give an error.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null,
    string: []const u8,
    list: []const *const Value,
    map: []const Entry,

    pub const Entry = struct { key: []const u8, value: *const Value };

    /// The value of `key` in a map, or null (also for a value that is not
    /// a map).
    pub fn get(v: *const Value, key: []const u8) ?*const Value {
        if (v.* != .map) return null;
        var i = v.map.len;
        // The last entry of a key wins (an entry after a merge key).
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, v.map[i].key, key)) return v.map[i].value;
        }
        return null;
    }

    /// The text of a scalar, or null.
    pub fn str(v: *const Value) ?[]const u8 {
        return if (v.* == .string) v.string else null;
    }

    /// The items of a list. A scalar is a list of one item, and null is an
    /// empty list (`files: a.stl` and `files: [a.stl]` are the same).
    pub fn items(v: *const Value, arena: Allocator) Allocator.Error![]const *const Value {
        return switch (v.*) {
            .list => |l| l,
            .null => &.{},
            else => blk: {
                const one = try arena.alloc(*const Value, 1);
                one[0] = v;
                break :blk one;
            },
        };
    }
};

pub const Diagnostic = struct {
    /// The line of the error (1 is the first line), or 0.
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{ BadYaml, OutOfMemory };

const Line = struct {
    /// The number of spaces before the text.
    indent: usize,
    /// The text, with no comment and no space at the end.
    text: []const u8,
    /// The line in the file (1 is the first line).
    number: usize,
};

/// Reads a YAML document. The values are allocated in `arena`.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!*const Value {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    var raw_lines: std.ArrayList([]const u8) = .empty;
    while (it.next()) |raw0| {
        number += 1;
        const raw = std.mem.trimEnd(u8, raw0, "\r");
        try raw_lines.append(arena, raw);
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        if (indent < raw.len and raw[indent] == '\t') return fail(diag, number, "a tab in the indent (use spaces)");
        const body = std.mem.trimEnd(u8, stripComment(raw[indent..]), " \t");
        if (body.len == 0) {
            // An empty line: block scalars keep it.
            try lines.append(arena, .{ .indent = indent, .text = "", .number = number });
            continue;
        }
        if (indent == 0 and (std.mem.eql(u8, body, "---") or std.mem.eql(u8, body, "..."))) {
            if (body[0] == '-' and hasContent(lines.items)) return fail(diag, number, "more than one document");
            continue;
        }
        if (indent == 0 and body[0] == '%') continue; // a directive
        try lines.append(arena, .{ .indent = indent, .text = body, .number = number });
    }
    var p: Parser = .{ .arena = arena, .lines = lines.items, .raw = raw_lines.items, .diag = diag };
    p.skipEmpty();
    if (p.pos >= p.lines.len) return p.make(.null);
    const v = try p.node(p.lines[p.pos].indent);
    p.skipEmpty();
    if (p.pos < p.lines.len) return fail(diag, p.lines[p.pos].number, "text at a bad indent");
    return v;
}

fn hasContent(lines: []const Line) bool {
    for (lines) |l| if (l.text.len > 0) return true;
    return false;
}

fn fail(diag: *Diagnostic, line: usize, message: []const u8) Error {
    diag.* = .{ .line = line, .message = message };
    return error.BadYaml;
}

/// The text before a comment: a `#` at the start or after a space, and
/// not in quotes.
fn stripComment(text: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        // A quote opens only at the start of a scalar.
        if ((c == '"' or c == '\'') and (i == 0 or std.mem.indexOfScalar(u8, " [{,:-", text[i - 1]) != null)) {
            quote = c;
            continue;
        }
        if (c == '#' and (i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t')) return text[0..i];
    }
    return text;
}

const Parser = struct {
    arena: Allocator,
    lines: []Line,
    raw: []const []const u8,
    diag: *Diagnostic,
    pos: usize = 0,
    anchors: std.StringHashMapUnmanaged(*const Value) = .empty,

    fn make(p: *Parser, v: Value) Error!*const Value {
        const out = try p.arena.create(Value);
        out.* = v;
        return out;
    }

    fn skipEmpty(p: *Parser) void {
        while (p.pos < p.lines.len and p.lines[p.pos].text.len == 0) p.pos += 1;
    }

    fn here(p: *Parser) usize {
        return if (p.pos < p.lines.len) p.lines[p.pos].number else if (p.lines.len > 0) p.lines[p.lines.len - 1].number else 0;
    }

    /// The block node at line p.pos, at `indent`.
    fn node(p: *Parser, indent: usize) Error!*const Value {
        p.skipEmpty();
        if (p.pos >= p.lines.len) return p.make(.null);
        const l = p.lines[p.pos];
        if (isItem(l.text)) return p.list(indent);
        if (keySplit(l.text) != null) return p.map(indent);
        // A scalar or a flow node alone, maybe over more lines.
        p.pos += 1;
        return p.inlineValue(l.text, indent, l.number);
    }

    fn list(p: *Parser, indent: usize) Error!*const Value {
        var out: std.ArrayList(*const Value) = .empty;
        while (true) {
            p.skipEmpty();
            if (p.pos >= p.lines.len) break;
            const l = &p.lines[p.pos];
            if (l.indent != indent or !isItem(l.text)) break;
            var rest = l.text[1..];
            var skip: usize = 1;
            while (skip < l.text.len and l.text[skip] == ' ') skip += 1;
            rest = l.text[skip..];
            if (rest.len == 0) {
                // The item is the block under the dash.
                p.pos += 1;
                p.skipEmpty();
                if (p.pos < p.lines.len and p.lines[p.pos].indent > indent) {
                    try out.append(p.arena, try p.node(p.lines[p.pos].indent));
                } else {
                    try out.append(p.arena, try p.make(.null));
                }
                continue;
            }
            // The item starts on the line of the dash: the line becomes the
            // first line of the item, at the column of its text.
            l.indent = indent + skip;
            l.text = rest;
            try out.append(p.arena, try p.node(l.indent));
        }
        return p.make(.{ .list = out.items });
    }

    fn map(p: *Parser, indent: usize) Error!*const Value {
        var out: std.ArrayList(Value.Entry) = .empty;
        while (true) {
            p.skipEmpty();
            if (p.pos >= p.lines.len) break;
            const l = p.lines[p.pos];
            if (l.indent != indent) {
                if (l.indent > indent) return fail(p.diag, l.number, "text at a bad indent");
                break;
            }
            const kv = keySplit(l.text) orelse return fail(p.diag, l.number, "a line that is not \"key: value\" in a map");
            const key = try p.scalarText(kv.key, l.number);
            p.pos += 1;
            var rest = kv.value;
            var anchor: ?[]const u8 = null;
            if (rest.len > 0 and rest[0] == '&') {
                const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
                anchor = rest[1..end];
                rest = std.mem.trimStart(u8, rest[end..], " ");
            }
            var value: *const Value = undefined;
            if (rest.len == 0) {
                p.skipEmpty();
                if (p.pos < p.lines.len and p.lines[p.pos].indent > indent) {
                    value = try p.node(p.lines[p.pos].indent);
                } else if (p.pos < p.lines.len and p.lines[p.pos].indent == indent and isItem(p.lines[p.pos].text)) {
                    // A list at the indent of its key.
                    value = try p.list(indent);
                } else {
                    value = try p.make(.null);
                }
            } else if (rest[0] == '|' or rest[0] == '>') {
                value = try p.blockScalar(rest, indent, l.number);
            } else {
                value = try p.inlineValue(rest, indent, l.number);
            }
            if (anchor) |a| try p.anchors.put(p.arena, a, value);
            if (std.mem.eql(u8, key, "<<")) {
                // The merge key: the entries of the map (or maps) come in
                // first; the later keys of this map win (Value.get).
                const sources = try value.items(p.arena);
                for (sources) |src| {
                    if (src.* != .map) return fail(p.diag, l.number, "the merge key needs a map");
                    try out.appendSlice(p.arena, src.map);
                }
                continue;
            }
            try out.append(p.arena, .{ .key = key, .value = value });
        }
        return p.make(.{ .map = out.items });
    }

    /// A value on the line of its key or dash: an alias, a flow node (which
    /// can go on over the next lines), or a plain or quoted scalar (a plain
    /// scalar can go on over the next lines with a larger indent).
    fn inlineValue(p: *Parser, text: []const u8, indent: usize, number: usize) Error!*const Value {
        if (text[0] == '*') {
            const name = std.mem.trim(u8, text[1..], " ");
            return p.anchors.get(name) orelse fail(p.diag, number, "an alias of an anchor that is not there");
        }
        if (text[0] == '[' or text[0] == '{') {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(p.arena, text);
            while (!balanced(buf.items)) {
                if (p.pos >= p.lines.len) return fail(p.diag, number, "a [ or { with no end");
                const next = p.lines[p.pos];
                p.pos += 1;
                if (next.text.len == 0) continue;
                try buf.append(p.arena, ' ');
                try buf.appendSlice(p.arena, next.text);
            }
            var f: Flow = .{ .p = p, .text = buf.items, .number = number };
            const v = try f.value();
            f.space();
            if (f.i != f.text.len) return fail(p.diag, number, "text after the end of a flow node");
            return v;
        }
        if (text[0] == '"' or text[0] == '\'') return p.make(.{ .string = try p.scalarText(text, number) });
        // A plain scalar, maybe folded over the next lines.
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(p.arena, text);
        while (p.pos < p.lines.len) {
            const next = p.lines[p.pos];
            if (next.text.len == 0 or next.indent <= indent or isItem(next.text) or keySplit(next.text) != null) break;
            try buf.append(p.arena, ' ');
            try buf.appendSlice(p.arena, next.text);
            p.pos += 1;
        }
        if (std.mem.eql(u8, buf.items, "~") or std.mem.eql(u8, buf.items, "null")) return p.make(.null);
        return p.make(.{ .string = buf.items });
    }

    /// A folded (>) or literal (|) block scalar: the lines under the key
    /// with a larger indent. The indent of the first line is the indent of
    /// the block.
    fn blockScalar(p: *Parser, head: []const u8, indent: usize, number: usize) Error!*const Value {
        const folded = head[0] == '>';
        var chomp: u8 = ' ';
        for (head[1..]) |c| switch (c) {
            '-', '+' => chomp = c,
            '1'...'9' => return fail(p.diag, number, "an indent number on a block scalar"),
            else => return fail(p.diag, number, "a bad block scalar head"),
        };
        // The raw lines keep the text after a #.
        var block_indent: ?usize = null;
        var lines: std.ArrayList([]const u8) = .empty;
        while (p.pos < p.lines.len) {
            const l = p.lines[p.pos];
            const raw = p.raw[l.number - 1];
            if (l.text.len == 0 and std.mem.trim(u8, raw, " ").len == 0) {
                try lines.append(p.arena, "");
                p.pos += 1;
                continue;
            }
            if (l.indent <= indent) break;
            const bi = block_indent orelse l.indent;
            block_indent = bi;
            if (l.indent < bi) break;
            try lines.append(p.arena, std.mem.trimEnd(u8, raw[bi..], " "));
            p.pos += 1;
        }
        // The empty lines at the end are not in the block (with clip and
        // strip).
        var n = lines.items.len;
        var trailing: usize = 0;
        while (n > 0 and lines.items[n - 1].len == 0) {
            n -= 1;
            trailing += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        for (lines.items[0..n], 0..) |line, i| {
            if (!folded) {
                if (i > 0) try out.append(p.arena, '\n');
            } else if (line.len == 0) {
                // Folding: an empty line is a line break.
                try out.append(p.arena, '\n');
            } else if (i > 0 and lines.items[i - 1].len != 0) {
                // Lines join with a space; a more indented line keeps its
                // line break.
                const more = line[0] == ' ' or lines.items[i - 1][0] == ' ';
                try out.append(p.arena, if (more) '\n' else ' ');
            }
            try out.appendSlice(p.arena, line);
        }
        if (n > 0) switch (chomp) {
            '-' => {},
            '+' => for (0..trailing + 1) |_| try out.append(p.arena, '\n'),
            else => try out.append(p.arena, '\n'),
        };
        return p.make(.{ .string = out.items });
    }

    /// The text of a plain or quoted scalar (a key, or a value).
    fn scalarText(p: *Parser, text: []const u8, number: usize) Error![]const u8 {
        if (text.len == 0) return text;
        if (text[0] == '\'') {
            if (text.len < 2 or text[text.len - 1] != '\'') return fail(p.diag, number, "a ' with no end");
            return std.mem.replaceOwned(u8, p.arena, text[1 .. text.len - 1], "''", "'");
        }
        if (text[0] == '"') {
            if (text.len < 2 or text[text.len - 1] != '"') return fail(p.diag, number, "a \" with no end");
            return p.unescape(text[1 .. text.len - 1], number);
        }
        return text;
    }

    fn unescape(p: *Parser, text: []const u8, number: usize) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '\\') {
                try out.append(p.arena, text[i]);
                continue;
            }
            i += 1;
            if (i >= text.len) return fail(p.diag, number, "a \\ at the end of a string");
            try out.append(p.arena, switch (text[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                '"', '\\', '/', ' ' => text[i],
                else => return fail(p.diag, number, "an escape that zslice does not read"),
            });
        }
        return out.items;
    }
};

/// A line that is a list item: "-" alone, or "- " and the item.
fn isItem(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

/// The key and the value of a "key: value" line (also "key:"), or null.
/// The key can be quoted.
fn keySplit(text: []const u8) ?struct { key: []const u8, value: []const u8 } {
    if (text.len == 0 or text[0] == '[' or text[0] == '{' or text[0] == '&' or text[0] == '*') return null;
    var i: usize = 0;
    if (text[0] == '"' or text[0] == '\'') {
        const q = text[0];
        i = 1;
        while (i < text.len and text[i] != q) : (i += 1) {
            if (q == '"' and text[i] == '\\') i += 1;
        }
        if (i >= text.len) return null;
        i += 1;
        if (i >= text.len or text[i] != ':') return null;
    } else {
        while (i < text.len) : (i += 1) {
            if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')) break;
        } else return null;
    }
    return .{ .key = std.mem.trimEnd(u8, text[0..i], " "), .value = std.mem.trim(u8, text[i + 1 ..], " ") };
}

/// True when the [ and { of a flow text have their ends (out of quotes).
fn balanced(text: []const u8) bool {
    var depth: i32 = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                i += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            else => {},
        }
    }
    return depth <= 0;
}

/// A flow node: [a, b] and {k: v}, nested.
const Flow = struct {
    p: *Parser,
    text: []const u8,
    number: usize,
    i: usize = 0,

    fn space(f: *Flow) void {
        while (f.i < f.text.len and (f.text[f.i] == ' ' or f.text[f.i] == '\t')) f.i += 1;
    }

    fn bad(f: *Flow, message: []const u8) Error {
        return fail(f.p.diag, f.number, message);
    }

    fn value(f: *Flow) Error!*const Value {
        f.space();
        if (f.i >= f.text.len) return f.bad("a flow node with no end");
        const c = f.text[f.i];
        if (c == '[') {
            f.i += 1;
            var out: std.ArrayList(*const Value) = .empty;
            while (true) {
                f.space();
                if (f.i < f.text.len and f.text[f.i] == ']') {
                    f.i += 1;
                    break;
                }
                try out.append(f.p.arena, try f.value());
                f.space();
                if (f.i >= f.text.len) return f.bad("a [ with no ]");
                if (f.text[f.i] == ',') {
                    f.i += 1;
                } else if (f.text[f.i] != ']') return f.bad("a flow list item with no , after it");
            }
            return f.p.make(.{ .list = out.items });
        }
        if (c == '{') {
            f.i += 1;
            var out: std.ArrayList(Value.Entry) = .empty;
            while (true) {
                f.space();
                if (f.i < f.text.len and f.text[f.i] == '}') {
                    f.i += 1;
                    break;
                }
                const key = try f.scalar(true);
                f.space();
                if (f.i >= f.text.len or f.text[f.i] != ':') return f.bad("a flow map entry with no :");
                f.i += 1;
                f.space();
                const v = if (f.i < f.text.len and (f.text[f.i] == ',' or f.text[f.i] == '}')) try f.p.make(.null) else try f.value();
                try out.append(f.p.arena, .{ .key = key, .value = v });
                f.space();
                if (f.i >= f.text.len) return f.bad("a { with no }");
                if (f.text[f.i] == ',') {
                    f.i += 1;
                } else if (f.text[f.i] != '}') return f.bad("a flow map entry with no , after it");
            }
            return f.p.make(.{ .map = out.items });
        }
        if (c == '*') {
            f.i += 1;
            const start = f.i;
            while (f.i < f.text.len and std.mem.indexOfScalar(u8, " ,]}", f.text[f.i]) == null) f.i += 1;
            return f.p.anchors.get(f.text[start..f.i]) orelse f.bad("an alias of an anchor that is not there");
        }
        const s = try f.scalar(false);
        if (std.mem.eql(u8, s, "~") or std.mem.eql(u8, s, "null")) return f.p.make(.null);
        return f.p.make(.{ .string = s });
    }

    /// A scalar in a flow node. A plain key ends at ": " or ":" before a
    /// , or }; a plain value ends at , ] or }.
    fn scalar(f: *Flow, is_key: bool) Error![]const u8 {
        f.space();
        if (f.i < f.text.len and (f.text[f.i] == '"' or f.text[f.i] == '\'')) {
            const q = f.text[f.i];
            const start = f.i;
            f.i += 1;
            while (f.i < f.text.len) : (f.i += 1) {
                if (q == '"' and f.text[f.i] == '\\') {
                    f.i += 1;
                    continue;
                }
                if (f.text[f.i] == q) {
                    if (q == '\'' and f.i + 1 < f.text.len and f.text[f.i + 1] == '\'') {
                        f.i += 1;
                        continue;
                    }
                    break;
                }
            } else return f.bad("a quote with no end");
            f.i += 1;
            return f.p.scalarText(f.text[start..f.i], f.number);
        }
        const start = f.i;
        while (f.i < f.text.len) : (f.i += 1) {
            const c = f.text[f.i];
            if (c == ',' or c == ']' or c == '}') break;
            if (is_key and c == ':' and (f.i + 1 == f.text.len or std.mem.indexOfScalar(u8, " ,}", f.text[f.i + 1]) != null)) break;
            if (!is_key and c == ':' and f.i + 1 < f.text.len and f.text[f.i + 1] == ' ') return f.bad("a : in a plain flow value (quote it)");
        }
        return std.mem.trimEnd(u8, f.text[start..f.i], " \t");
    }
};

const testing = std.testing;

fn testParse(arena: Allocator, text: []const u8) !*const Value {
    var diag: Diagnostic = .{};
    return parse(arena, text, &diag) catch |e| {
        std.debug.print("line {d}: {s}\n", .{ diag.line, diag.message });
        return e;
    };
}

test "yaml: the shape of a printdeck.yml" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try testParse(a,
        \\# A comment
        \\project: printdeck   # the slug
        \\
        \\generate:
        \\  install: pip install -r lulzbot/requirements.txt
        \\  check: true
        \\materials:
        \\  roll-4:
        \\    buy:
        \\      2.85 mm: https://example.com/a#frag
        \\parts:
        \\  # The first group.
        \\  - name: Slate frame
        \\    description: >-
        \\      The frame goes around the display.
        \\      It prints on its back.
        \\
        \\      A second paragraph.
        \\    files: [lulzbot/stl/a.stl, "b c.stl"]
        \\    count: 4
        \\    settings: &slate {support_enable: false, z_seam_type: sharpest_corner,
        \\                      adhesion_type: brim, brim_line_count: 10}
        \\  - name: Slate body
        \\    files:
        \\    - x.stl
        \\    settings: *slate
        \\  - name: 'It''s'
        \\    note: a plain text
        \\      over two lines
        \\    text: |
        \\      line 1
        \\        line 2
        \\    variants:
        \\      - name: fine
        \\        settings:
        \\          <<: *slate
        \\          brim_line_count: 14
        \\
    );
    try testing.expectEqualStrings("printdeck", v.get("project").?.str().?);
    try testing.expectEqualStrings("true", v.get("generate").?.get("check").?.str().?);
    try testing.expectEqualStrings("https://example.com/a#frag", v.get("materials").?.get("roll-4").?.get("buy").?.get("2.85 mm").?.str().?);
    const parts = v.get("parts").?.list;
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("Slate frame", parts[0].get("name").?.str().?);
    try testing.expectEqualStrings("The frame goes around the display. It prints on its back.\nA second paragraph.", parts[0].get("description").?.str().?);
    const files = parts[0].get("files").?.list;
    try testing.expectEqualStrings("b c.stl", files[1].str().?);
    try testing.expectEqualStrings("10", parts[0].get("settings").?.get("brim_line_count").?.str().?);
    try testing.expectEqualStrings("x.stl", parts[1].get("files").?.list[0].str().?);
    try testing.expectEqualStrings("brim", parts[1].get("settings").?.get("adhesion_type").?.str().?);
    try testing.expectEqualStrings("It's", parts[2].get("name").?.str().?);
    try testing.expectEqualStrings("a plain text over two lines", parts[2].get("note").?.str().?);
    try testing.expectEqualStrings("line 1\n  line 2\n", parts[2].get("text").?.str().?);
    const fine = parts[2].get("variants").?.list[0].get("settings").?;
    try testing.expectEqualStrings("14", fine.get("brim_line_count").?.str().?);
    try testing.expectEqualStrings("false", fine.get("support_enable").?.str().?);
}

test "yaml: errors name the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    try testing.expectError(error.BadYaml, parse(a, "a: [1, 2\nb: 3\n", &diag));
    try testing.expectError(error.BadYaml, parse(a, "a: 1\n  b: 2\n", &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expectError(error.BadYaml, parse(a, "a: *nope\n", &diag));
}
