//! Expressions: the formulas of the settings ("= {line_width} * 2") and,
//! later, the functions that run for each segment of a layer.
//!
//! The language:
//!
//! - Numbers (`0.4`, `2`, `1e-3`) and texts in double quotes (`"PLA"`).
//! - `{name}`: the value of a variable, for example a setting
//!   (`{project.line_width}`, or `{line_width}` when the caller looks the
//!   short name up). The caller gives the values through `Env`.
//! - Arithmetic: `+ - * / %`, `^` (a power, right to left), and a minus
//!   sign in front. Parentheses group.
//! - Comparisons: `== != < <= > >=`. A text compares with `==` and `!=`.
//!   A comparison gives 1 (true) or 0 (false).
//! - Logic: `and`, `or`, `not`. Zero is false; any other number is true.
//! - A choice: `cond ? a : b`.
//! - Functions: `min(a, b, ...)`, `max(a, b, ...)`, `round(x)`,
//!   `round(x, step)` (to a multiple of step), `floor(x)`, `ceil(x)`,
//!   `abs(x)`, `sqrt(x)`, `clamp(x, lo, hi)`, `lerp(a, b, t)`.
//!
//! `parse` makes a tree (in an arena) once; `eval` runs it as often as
//! needed (for a segment function, once for each segment). An error has
//! the position in the text, for the editor.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A value: a number or a text.
pub const Value = union(enum) {
    num: f64,
    text: []const u8,

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .num => |n| n != 0,
            .text => |t| t.len > 0,
        };
    }
};

/// The values of the variables of an expression.
pub const Env = struct {
    ctx: ?*const anyopaque = null,
    /// The value of a variable, or null if there is none of that name.
    lookup: *const fn (ctx: ?*const anyopaque, name: []const u8) ?Value,
};

pub const Error = error{ Syntax, UnknownVariable, UnknownFunction, BadArguments, NotANumber, OutOfMemory };

/// The place of an error: its byte in the text, and what is wrong.
pub const Diagnostic = struct {
    pos: usize = 0,
    message: []const u8 = "",
};

const Op = enum { add, sub, mul, div, mod, pow, neg, eq, ne, lt, le, gt, ge, @"and", @"or", not };

pub const Node = union(enum) {
    num: f64,
    text: []const u8,
    variable: []const u8,
    unary: struct { op: Op, a: *const Node },
    binary: struct { op: Op, a: *const Node, b: *const Node },
    choice: struct { cond: *const Node, a: *const Node, b: *const Node },
    call: struct { name: []const u8, args: []const *const Node },
};

/// The names of the variables that an expression uses (for the order of
/// the formulas of the settings), in `arena`.
pub fn variables(arena: Allocator, node: *const Node) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try collect(arena, node, &out);
    return out.items;
}

fn collect(arena: Allocator, node: *const Node, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    switch (node.*) {
        .num, .text => {},
        .variable => |n| {
            for (out.items) |o| if (std.mem.eql(u8, o, n)) return;
            try out.append(arena, n);
        },
        .unary => |u| try collect(arena, u.a, out),
        .binary => |b| {
            try collect(arena, b.a, out);
            try collect(arena, b.b, out);
        },
        .choice => |c| {
            try collect(arena, c.cond, out);
            try collect(arena, c.a, out);
            try collect(arena, c.b, out);
        },
        .call => |c| for (c.args) |a| try collect(arena, a, out),
    }
}

// ---- the parser: a recursive descent, from the lowest precedence ----

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,
    diag: *Diagnostic,

    fn fail(p: *Parser, message: []const u8) Error {
        p.diag.* = .{ .pos = p.pos, .message = message };
        return error.Syntax;
    }

    fn skip(p: *Parser) void {
        while (p.pos < p.text.len and std.ascii.isWhitespace(p.text[p.pos])) p.pos += 1;
    }

    fn eat(p: *Parser, s: []const u8) bool {
        p.skip();
        if (std.mem.startsWith(u8, p.text[p.pos..], s)) {
            // A word (and, or, not) must end there.
            if (std.ascii.isAlphabetic(s[0])) {
                const end = p.pos + s.len;
                if (end < p.text.len and (std.ascii.isAlphanumeric(p.text[end]) or p.text[end] == '_')) return false;
            }
            p.pos += s.len;
            return true;
        }
        return false;
    }

    fn node(p: *Parser, n: Node) Error!*const Node {
        const out = try p.arena.create(Node);
        out.* = n;
        return out;
    }

    fn choice(p: *Parser) Error!*const Node {
        const cond = try p.orExpr();
        if (!p.eat("?")) return cond;
        const a = try p.choice();
        if (!p.eat(":")) return p.fail("a ':' after the '?' part");
        const b = try p.choice();
        return p.node(.{ .choice = .{ .cond = cond, .a = a, .b = b } });
    }

    fn orExpr(p: *Parser) Error!*const Node {
        var a = try p.andExpr();
        while (p.eat("or")) a = try p.node(.{ .binary = .{ .op = .@"or", .a = a, .b = try p.andExpr() } });
        return a;
    }

    fn andExpr(p: *Parser) Error!*const Node {
        var a = try p.notExpr();
        while (p.eat("and")) a = try p.node(.{ .binary = .{ .op = .@"and", .a = a, .b = try p.notExpr() } });
        return a;
    }

    fn notExpr(p: *Parser) Error!*const Node {
        if (p.eat("not")) return p.node(.{ .unary = .{ .op = .not, .a = try p.notExpr() } });
        return p.compare();
    }

    fn compare(p: *Parser) Error!*const Node {
        const a = try p.sum();
        const ops = [_]struct { s: []const u8, op: Op }{
            .{ .s = "==", .op = .eq }, .{ .s = "!=", .op = .ne }, .{ .s = "<=", .op = .le },
            .{ .s = ">=", .op = .ge }, .{ .s = "<", .op = .lt },  .{ .s = ">", .op = .gt },
        };
        for (ops) |o| if (p.eat(o.s)) return p.node(.{ .binary = .{ .op = o.op, .a = a, .b = try p.sum() } });
        return a;
    }

    fn sum(p: *Parser) Error!*const Node {
        var a = try p.product();
        while (true) {
            if (p.eat("+")) {
                a = try p.node(.{ .binary = .{ .op = .add, .a = a, .b = try p.product() } });
            } else if (p.eat("-")) {
                a = try p.node(.{ .binary = .{ .op = .sub, .a = a, .b = try p.product() } });
            } else return a;
        }
    }

    fn product(p: *Parser) Error!*const Node {
        var a = try p.unary();
        while (true) {
            if (p.eat("*")) {
                a = try p.node(.{ .binary = .{ .op = .mul, .a = a, .b = try p.unary() } });
            } else if (p.eat("/")) {
                a = try p.node(.{ .binary = .{ .op = .div, .a = a, .b = try p.unary() } });
            } else if (p.eat("%")) {
                a = try p.node(.{ .binary = .{ .op = .mod, .a = a, .b = try p.unary() } });
            } else return a;
        }
    }

    fn unary(p: *Parser) Error!*const Node {
        if (p.eat("-")) return p.node(.{ .unary = .{ .op = .neg, .a = try p.unary() } });
        if (p.eat("+")) return p.unary();
        return p.power();
    }

    fn power(p: *Parser) Error!*const Node {
        const a = try p.atom();
        // Right to left: 2 ^ 3 ^ 2 is 2 ^ 9.
        if (p.eat("^")) return p.node(.{ .binary = .{ .op = .pow, .a = a, .b = try p.unary() } });
        return a;
    }

    fn atom(p: *Parser) Error!*const Node {
        p.skip();
        if (p.pos >= p.text.len) return p.fail("a value at the end");
        const c = p.text[p.pos];
        if (c == '(') {
            p.pos += 1;
            const inner = try p.choice();
            if (!p.eat(")")) return p.fail("a ')'");
            return inner;
        }
        if (c == '{') {
            const start = p.pos + 1;
            const end = std.mem.indexOfScalarPos(u8, p.text, start, '}') orelse return p.fail("a '}' after the name");
            const name = std.mem.trim(u8, p.text[start..end], " ");
            if (name.len == 0) return p.fail("a name in the braces");
            p.pos = end + 1;
            return p.node(.{ .variable = name });
        }
        if (c == '"') {
            const end = std.mem.indexOfScalarPos(u8, p.text, p.pos + 1, '"') orelse return p.fail("a '\"' at the end of the text");
            const t = p.text[p.pos + 1 .. end];
            p.pos = end + 1;
            return p.node(.{ .text = t });
        }
        if (std.ascii.isDigit(c) or c == '.') {
            var end = p.pos;
            while (end < p.text.len and (std.ascii.isDigit(p.text[end]) or p.text[end] == '.' or
                ((p.text[end] == 'e' or p.text[end] == 'E') and end + 1 < p.text.len) or
                ((p.text[end] == '-' or p.text[end] == '+') and end > p.pos and (p.text[end - 1] == 'e' or p.text[end - 1] == 'E')))) end += 1;
            const n = std.fmt.parseFloat(f64, p.text[p.pos..end]) catch return p.fail("a number");
            p.pos = end;
            return p.node(.{ .num = n });
        }
        if (std.ascii.isAlphabetic(c)) {
            var end = p.pos;
            while (end < p.text.len and (std.ascii.isAlphanumeric(p.text[end]) or p.text[end] == '_')) end += 1;
            const name = p.text[p.pos..end];
            p.pos = end;
            if (std.mem.eql(u8, name, "true")) return p.node(.{ .num = 1 });
            if (std.mem.eql(u8, name, "false")) return p.node(.{ .num = 0 });
            if (!p.eat("(")) return p.fail("a '(' after the name of the function (a variable is in braces: {name})");
            var args: std.ArrayList(*const Node) = .empty;
            if (!p.eat(")")) {
                while (true) {
                    try args.append(p.arena, try p.choice());
                    if (p.eat(")")) break;
                    if (!p.eat(",")) return p.fail("a ',' or a ')'");
                }
            }
            return p.node(.{ .call = .{ .name = name, .args = args.items } });
        }
        return p.fail("a number, a {name}, a text, a function, or '('");
    }
};

/// Parses `text` (with no leading '='). The tree is in `arena`.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!*const Node {
    var p: Parser = .{ .arena = arena, .text = text, .diag = diag };
    const n = try p.choice();
    p.skip();
    if (p.pos != text.len) return p.fail("the end of the formula");
    return n;
}

// ---- the evaluation ----

fn num(v: Value) Error!f64 {
    return switch (v) {
        .num => |n| n,
        .text => |t| std.fmt.parseFloat(f64, t) catch error.NotANumber,
    };
}

fn boolNum(b: bool) Value {
    return .{ .num = if (b) 1 else 0 };
}

pub fn eval(node: *const Node, env: Env) Error!Value {
    switch (node.*) {
        .num => |n| return .{ .num = n },
        .text => |t| return .{ .text = t },
        .variable => |name| return env.lookup(env.ctx, name) orelse error.UnknownVariable,
        .unary => |u| {
            const a = try eval(u.a, env);
            return switch (u.op) {
                .neg => .{ .num = -(try num(a)) },
                .not => boolNum(!a.truthy()),
                else => unreachable,
            };
        },
        .binary => |b| {
            // and, or: the right side only when needed.
            if (b.op == .@"and") {
                if (!(try eval(b.a, env)).truthy()) return boolNum(false);
                return boolNum((try eval(b.b, env)).truthy());
            }
            if (b.op == .@"or") {
                if ((try eval(b.a, env)).truthy()) return boolNum(true);
                return boolNum((try eval(b.b, env)).truthy());
            }
            const a = try eval(b.a, env);
            const c = try eval(b.b, env);
            // A text: only == and !=.
            if (a == .text or c == .text) {
                if (b.op == .eq or b.op == .ne) {
                    const same = if (a == .text and c == .text) std.mem.eql(u8, a.text, c.text) else blk: {
                        const x = num(a) catch break :blk false;
                        const y = num(c) catch break :blk false;
                        break :blk x == y;
                    };
                    return boolNum(if (b.op == .eq) same else !same);
                }
            }
            const x = try num(a);
            const y = try num(c);
            return switch (b.op) {
                .add => .{ .num = x + y },
                .sub => .{ .num = x - y },
                .mul => .{ .num = x * y },
                .div => .{ .num = x / y },
                .mod => .{ .num = @mod(x, y) },
                .pow => .{ .num = std.math.pow(f64, x, y) },
                .eq => boolNum(x == y),
                .ne => boolNum(x != y),
                .lt => boolNum(x < y),
                .le => boolNum(x <= y),
                .gt => boolNum(x > y),
                .ge => boolNum(x >= y),
                else => unreachable,
            };
        },
        .choice => |ch| return if ((try eval(ch.cond, env)).truthy()) eval(ch.a, env) else eval(ch.b, env),
        .call => |c| return call(c.name, c.args, env),
    }
}

fn call(name: []const u8, args: []const *const Node, env: Env) Error!Value {
    var vals: [8]f64 = undefined;
    if (args.len > vals.len) return error.BadArguments;
    for (args, 0..) |a, i| vals[i] = try num(try eval(a, env));
    const v = vals[0..args.len];
    const eq = std.mem.eql;
    if (eq(u8, name, "min") or eq(u8, name, "max")) {
        if (v.len == 0) return error.BadArguments;
        var r = v[0];
        for (v[1..]) |x| r = if (eq(u8, name, "min")) @min(r, x) else @max(r, x);
        return .{ .num = r };
    }
    if (eq(u8, name, "round")) {
        if (v.len == 1) return .{ .num = @round(v[0]) };
        if (v.len == 2 and v[1] != 0) return .{ .num = @round(v[0] / v[1]) * v[1] };
        return error.BadArguments;
    }
    const one = [_]struct { n: []const u8, f: *const fn (f64) f64 }{
        .{ .n = "floor", .f = struct {
            fn f(x: f64) f64 {
                return @floor(x);
            }
        }.f },
        .{ .n = "ceil", .f = struct {
            fn f(x: f64) f64 {
                return @ceil(x);
            }
        }.f },
        .{ .n = "abs", .f = struct {
            fn f(x: f64) f64 {
                return @abs(x);
            }
        }.f },
        .{ .n = "sqrt", .f = struct {
            fn f(x: f64) f64 {
                return @sqrt(x);
            }
        }.f },
    };
    for (one) |o| if (eq(u8, name, o.n)) {
        if (v.len != 1) return error.BadArguments;
        return .{ .num = o.f(v[0]) };
    };
    if (eq(u8, name, "clamp")) {
        if (v.len != 3) return error.BadArguments;
        return .{ .num = std.math.clamp(v[0], v[1], v[2]) };
    }
    if (eq(u8, name, "lerp")) {
        if (v.len != 3) return error.BadArguments;
        return .{ .num = v[0] + (v[1] - v[0]) * v[2] };
    }
    return error.UnknownFunction;
}

// ---- tests ----

const testing = std.testing;

fn testEnv(_: ?*const anyopaque, name: []const u8) ?Value {
    if (std.mem.eql(u8, name, "line_width")) return .{ .num = 0.45 };
    if (std.mem.eql(u8, name, "project.layer_height")) return .{ .num = 0.2 };
    if (std.mem.eql(u8, name, "feature")) return .{ .text = "outer_wall" };
    if (std.mem.eql(u8, name, "z")) return .{ .num = 3 };
    return null;
}

fn run(text: []const u8) !Value {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const n = try parse(arena_state.allocator(), text, &diag);
    const v = try eval(n, .{ .lookup = testEnv });
    // A text value points into the text: fine for the tests.
    return v;
}

fn expectNum(want: f64, text: []const u8) !void {
    const v = try run(text);
    try testing.expectApproxEqAbs(want, v.num, 1e-9);
}

test "expr: arithmetic and precedence" {
    try expectNum(7, "1 + 2 * 3");
    try expectNum(9, "(1 + 2) * 3");
    try expectNum(-4, "-2 * 2");
    try expectNum(512, "2 ^ 3 ^ 2");
    try expectNum(1, "7 % 3");
    try expectNum(0.0015, "1.5e-3");
}

test "expr: variables, functions, and choices" {
    try expectNum(0.9, "{line_width} * 2");
    try expectNum(0.8, "max({project.layer_height} * 4, 0.8)");
    try expectNum(0.4, "round(0.37, 0.2)");
    try expectNum(1, "clamp(5, 0, 1)");
    try expectNum(20, "{feature} == \"outer_wall\" and {z} < 5 ? 20 : 60");
    try expectNum(60, "{feature} != \"outer_wall\" ? 20 : 60");
    try expectNum(1, "not 0 or false");
    try expectNum(2.5, "lerp(0, 10, 0.25)");
}

test "expr: errors have a place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.Syntax, parse(arena_state.allocator(), "1 + ", &diag));
    try testing.expectEqual(@as(usize, 4), diag.pos);
    try testing.expectError(error.Syntax, parse(arena_state.allocator(), "line_width * 2", &diag));
    const n = try parse(arena_state.allocator(), "{nope} + 1", &diag);
    try testing.expectError(error.UnknownVariable, eval(n, .{ .lookup = testEnv }));
    const f = try parse(arena_state.allocator(), "tan(1)", &diag);
    try testing.expectError(error.UnknownFunction, eval(f, .{ .lookup = testEnv }));
    const vars = try variables(arena_state.allocator(), try parse(arena_state.allocator(), "{a} + {b} * {a}", &diag));
    try testing.expectEqual(@as(usize, 2), vars.len);
}
