//! Profiles: settings in human-readable TOML files.
//!
//! There are three kinds of profile, one for each settings group:
//! machine, filament, and project. A profile file has `key = value` lines
//! for the settings of its own group, without the group name:
//!
//!     # filament/acme-pla-gray.toml
//!     extends = "acme-pla"
//!     name = "Acme PLA Gray"
//!     nozzle_temp = 220
//!
//! Rules:
//!
//! - `extends = "name"` loads the base profile of the same group first.
//!   The keys of this file then replace the values of the base. A chain of
//!   `extends` can be up to 8 profiles long, and it cannot loop.
//! - A `[machine]`, `[filament]`, `[project]`, or `[engine]` table sets
//!   values of another group. This is how a project overrides one value of
//!   the filament, for example `[filament]` then `nozzle_temp = 230`.
//! - The load order of a slice is: machine, filament, project, then the
//!   overrides of the user (`-s` on the command line). Each step replaces
//!   the values of the steps before it.
//!
//! The core does no file I/O, so it gets the text of a base profile from a
//! `Resolver` that the caller gives. The command line tool and each app
//! shell have their own resolver. The built-in profiles (src/profiles/) are
//! the last place to look.

const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("toml.zig");
const settings_mod = @import("settings.zig");
const meta = @import("settings_meta.zig");
const Settings = settings_mod.Settings;

pub const Group = enum { machine, filament, project };

pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    /// Returns the text of profile `name` of `group`, allocated in `arena`,
    /// or null if there is no such profile. `from` is the name of the
    /// profile that asks (for a path relative to it), or "" for the first
    /// profile.
    load: *const fn (ctx: ?*anyopaque, arena: Allocator, group: Group, name: []const u8, from: []const u8) ?[]const u8,
};

pub const Diagnostic = struct {
    profile: []const u8 = "",
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{ ProfileNotFound, ProfileLoop, ProfileTooDeep, SyntaxError, UnknownSetting, InvalidValue, OutOfMemory };

/// Applies the profile `name` of `group` to `settings`. The profile and
/// its bases come from `resolver`, then from the built-in profiles. All
/// strings go in `arena`, which must live as long as `settings`.
pub fn load(arena: Allocator, settings: *Settings, group: Group, name: []const u8, resolver: ?Resolver, diag: *Diagnostic) Error!void {
    var chain: [max_depth][]const u8 = undefined;
    return loadDepth(arena, settings, group, name, "", resolver, diag, &chain, 0);
}

/// Applies a profile from its text. `name` is for the messages, and for
/// the `from` of its bases.
pub fn apply(arena: Allocator, settings: *Settings, group: Group, name: []const u8, text: []const u8, resolver: ?Resolver, diag: *Diagnostic) Error!void {
    var chain: [max_depth][]const u8 = undefined;
    chain[0] = name;
    return applyDepth(arena, settings, group, name, text, resolver, diag, &chain, 1);
}

const max_depth = 8;

fn loadDepth(arena: Allocator, settings: *Settings, group: Group, name: []const u8, from: []const u8, resolver: ?Resolver, diag: *Diagnostic, chain: *[max_depth][]const u8, depth: usize) Error!void {
    if (depth >= max_depth) {
        diag.* = .{ .profile = name, .message = "the extends chain is longer than 8 profiles" };
        return error.ProfileTooDeep;
    }
    for (chain[0..depth]) |c| {
        if (std.mem.eql(u8, c, name)) {
            diag.* = .{ .profile = name, .message = "the extends chain loops back to this profile" };
            return error.ProfileLoop;
        }
    }
    const text = blk: {
        if (resolver) |r| if (r.load(r.ctx, arena, group, name, from)) |t| break :blk t;
        if (builtin(group, name)) |t| break :blk t;
        diag.* = .{ .profile = name, .message = "no profile with this name" };
        return error.ProfileNotFound;
    };
    chain[depth] = name;
    return applyDepth(arena, settings, group, name, text, resolver, diag, chain, depth + 1);
}

fn applyDepth(arena: Allocator, settings: *Settings, group: Group, name: []const u8, text: []const u8, resolver: ?Resolver, diag: *Diagnostic, chain: *[max_depth][]const u8, depth: usize) Error!void {
    var tdiag: toml.Diagnostic = .{};
    const entries = toml.parse(arena, text, &tdiag) catch |e| {
        if (e == error.SyntaxError) diag.* = .{ .profile = name, .line = tdiag.line, .message = tdiag.message };
        return e;
    };

    // The base first.
    for (entries) |e| {
        if (e.table.len == 0 and std.mem.eql(u8, e.key, "extends")) {
            try loadDepth(arena, settings, group, e.value, name, resolver, diag, chain, depth);
        }
    }

    for (entries) |e| {
        if (e.table.len == 0 and std.mem.eql(u8, e.key, "extends")) continue;
        // A project has no name setting. Its name is for people only.
        if (e.table.len == 0 and group == .project and std.mem.eql(u8, e.key, "name")) continue;
        const target = if (e.table.len == 0) @tagName(group) else e.table;
        if (!isGroup(target)) {
            diag.* = .{ .profile = name, .line = e.line, .message = "unknown table: use [machine], [filament], [project], or [engine]" };
            return error.UnknownSetting;
        }
        const full = try std.fmt.allocPrint(arena, "{s}.{s}", .{ target, e.key });
        settings.set(full, e.value) catch |err| {
            diag.* = .{
                .profile = name,
                .line = e.line,
                .message = if (err == error.UnknownSetting) "unknown setting" else "the value has the wrong type for this setting",
            };
            return err;
        };
    }
}

fn isGroup(name: []const u8) bool {
    inline for (@typeInfo(Settings).@"struct".fields) |g| {
        if (std.mem.eql(u8, g.name, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Built-in profiles

pub const Builtin = struct { group: Group, name: []const u8, text: []const u8 };

pub const builtins = [_]Builtin{
    .{ .group = .machine, .name = "generic", .text = @embedFile("profiles/machine/generic.toml") },
    .{ .group = .machine, .name = "generic-bowden", .text = @embedFile("profiles/machine/generic-bowden.toml") },
    .{ .group = .filament, .name = "generic-pla", .text = @embedFile("profiles/filament/generic-pla.toml") },
    .{ .group = .filament, .name = "generic-petg", .text = @embedFile("profiles/filament/generic-petg.toml") },
    .{ .group = .filament, .name = "generic-abs", .text = @embedFile("profiles/filament/generic-abs.toml") },
    .{ .group = .filament, .name = "generic-tpu", .text = @embedFile("profiles/filament/generic-tpu.toml") },
    .{ .group = .project, .name = "standard", .text = @embedFile("profiles/project/standard.toml") },
    .{ .group = .project, .name = "draft", .text = @embedFile("profiles/project/draft.toml") },
    .{ .group = .project, .name = "fine", .text = @embedFile("profiles/project/fine.toml") },
    .{ .group = .project, .name = "strong", .text = @embedFile("profiles/project/strong.toml") },
};

pub fn builtin(group: Group, name: []const u8) ?[]const u8 {
    for (builtins) |b| {
        if (b.group == group and std.mem.eql(u8, b.name, name)) return b.text;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Write a profile

/// Writes all settings of `group` as a profile, with the help text of each
/// setting as a comment. A user can start a new profile from this output.
pub fn write(settings: Settings, group: Group, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("# A zslice {s} profile.\n", .{@tagName(group)});
    switch (group) {
        inline else => |g| {
            const values = @field(settings, @tagName(g));
            inline for (@typeInfo(@TypeOf(values)).@"struct".fields) |f| {
                const full = @tagName(g) ++ "." ++ f.name;
                const doc = comptime findDoc(full);
                try w.writeByte('\n');
                if (doc.len > 0) try writeComment(w, doc);
                try w.print("{s} = ", .{f.name});
                try writeValue(w, @field(values, f.name));
                try w.writeByte('\n');
            }
        },
    }
}

fn findDoc(comptime name: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    for (meta.all) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.doc;
    }
    return "";
}

/// Writes text as # comment lines of up to about 76 characters.
fn writeComment(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    var col: usize = 0;
    while (it.next()) |word| {
        if (col == 0) {
            try w.writeAll("#");
            col = 1;
        } else if (col + 1 + word.len > 76) {
            try w.writeAll("\n#");
            col = 1;
        }
        try w.print(" {s}", .{word});
        col += 1 + word.len;
    }
    if (col > 0) try w.writeByte('\n');
}

fn writeValue(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(v))) {
        .float, .int => try w.print("{d}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .@"enum" => try w.print("\"{s}\"", .{@tagName(v)}),
        .pointer => {
            if (std.mem.indexOfScalar(u8, v, '\n') != null) {
                // A multi-line literal string has no escapes. The newline
                // after the opening quotes is not part of the value.
                try w.print("'''\n{s}'''", .{v});
            } else {
                try w.writeByte('"');
                for (v) |c| switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                };
                try w.writeByte('"');
            }
        },
        else => @compileError("unsupported setting type"),
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestFiles = struct {
    files: []const struct { group: Group, name: []const u8, text: []const u8 },

    fn load(ctx: ?*anyopaque, arena: Allocator, group: Group, name: []const u8, from: []const u8) ?[]const u8 {
        _ = arena;
        _ = from;
        const self: *const TestFiles = @ptrCast(@alignCast(ctx.?));
        for (self.files) |f| {
            if (f.group == group and std.mem.eql(u8, f.name, name)) return f.text;
        }
        return null;
    }
};

test "a gray PLA extends a brand PLA, and a project overrides one value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: TestFiles = .{ .files = &.{
        .{ .group = .filament, .name = "acme-pla", .text = "extends = \"generic-pla\"\nname = \"Acme PLA\"\nnozzle_temp = 205\nbed_temp = 55\n" },
        .{ .group = .filament, .name = "acme-pla-gray", .text = "extends = \"acme-pla\"\nname = \"Acme PLA Gray\"\nnozzle_temp = 220\n" },
        .{ .group = .project, .name = "smooth", .text = "extends = \"fine\"\nname = \"Smooth\"\n\n[filament]\nnozzle_temp = 225\n" },
    } };
    const r: Resolver = .{ .ctx = &files, .load = TestFiles.load };
    var s: Settings = .{};
    var diag: Diagnostic = .{};
    try load(a, &s, .machine, "generic-bowden", r, &diag);
    try load(a, &s, .filament, "acme-pla-gray", r, &diag);
    try testing.expectEqualStrings("Acme PLA Gray", s.filament.name);
    try testing.expectEqual(@as(f64, 220), s.filament.nozzle_temp);
    try testing.expectEqual(@as(f64, 55), s.filament.bed_temp); // from acme-pla
    try testing.expectEqual(@as(f64, 12), s.filament.max_flow); // from generic-pla
    try testing.expectEqual(@as(f64, 5), s.machine.retract_length);
    try load(a, &s, .project, "smooth", r, &diag);
    try testing.expectEqual(@as(f64, 0.12), s.project.layer_height); // from fine
    try testing.expectEqual(true, s.project.ironing);
    try testing.expectEqual(@as(f64, 225), s.filament.nozzle_temp); // the project override
}

test "profile errors name the profile and the line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: TestFiles = .{ .files = &.{
        .{ .group = .filament, .name = "loop-a", .text = "extends = \"loop-b\"\n" },
        .{ .group = .filament, .name = "loop-b", .text = "extends = \"loop-a\"\n" },
        .{ .group = .filament, .name = "typo", .text = "name = \"x\"\n\nnozle_temp = 200\n" },
        .{ .group = .filament, .name = "badtype", .text = "nozzle_temp = \"hot\"\n" },
    } };
    const r: Resolver = .{ .ctx = &files, .load = TestFiles.load };
    var s: Settings = .{};
    var diag: Diagnostic = .{};
    try testing.expectError(error.ProfileLoop, load(a, &s, .filament, "loop-a", r, &diag));
    try testing.expectError(error.UnknownSetting, load(a, &s, .filament, "typo", r, &diag));
    try testing.expectEqualStrings("typo", diag.profile);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectError(error.InvalidValue, load(a, &s, .filament, "badtype", r, &diag));
    try testing.expectError(error.ProfileNotFound, load(a, &s, .filament, "nope", r, &diag));
}

test "each built-in profile loads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (builtins) |b| {
        var s: Settings = .{};
        var diag: Diagnostic = .{};
        load(arena.allocator(), &s, b.group, b.name, null, &diag) catch |e| {
            std.debug.print("{s}: line {d}: {s}\n", .{ b.name, diag.line, diag.message });
            return e;
        };
        _ = try s.resolve();
    }
}

test "a written profile loads back to the same values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Settings = .{};
    s.filament.nozzle_temp = 231.5;
    s.filament.name = "Quote \" and backslash \\";
    s.machine.extruder = .bowden;
    for ([_]Group{ .machine, .filament, .project }) |g| {
        var out: std.Io.Writer.Allocating = .init(a);
        try write(s, g, &out.writer);
        var back: Settings = .{};
        var diag: Diagnostic = .{};
        apply(a, &back, g, "written", out.written(), null, &diag) catch |e| {
            std.debug.print("line {d}: {s}\n{s}\n", .{ diag.line, diag.message, out.written() });
            return e;
        };
        switch (g) {
            inline else => |tag| try testing.expectEqualDeep(@field(s, @tagName(tag)), @field(back, @tagName(tag))),
        }
    }
}
