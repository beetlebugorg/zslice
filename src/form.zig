//! The slice form: the work of a slice that the app keeps for the next
//! slice, with the key of each piece.
//!
//! A slice runs a fixed chain of stages. Each stage makes one tier of
//! pieces: the placed mesh of a part (M), its outlines (G), the regions of
//! each layer (R), the move stream of each level (P), and the G-code text
//! of each level (X). A later slice makes a piece again only if its key
//! changed. A key is a hash of all inputs that the stages of the piece
//! read. Each piece has a fixed slot (a part, a layer, or a level), so a
//! slice compares the new key with the keys in the slot, and does not
//! search a table.
//!
//! A key reads every setting, minus a skip list for its tier
//! (settings_tiers.zig). A new setting is in each key until a test proves
//! that a tier does not read it. A key that misses an input gives a wrong
//! slice with no error, so the keys are safe by default.
//!
//! The rules of a piece (specs/200-slice-jit.md, section 6.4):
//!
//! 1. A slot holds a key and the data that the key made, as a pair. The
//!    key goes in last.
//! 2. A complete piece never changes.
//! 3. A piece has no pointer into a job, a settings struct, or another
//!    piece.
//! 4. The data is a pure function of the inputs of the key.
//!
//! References: memoization and function caching (W. Pugh, T. Teitelbaum,
//! 1989); early cutoff and verifying traces (A. Mokhov, N. Mitchell,
//! S. Peyton Jones, "Build Systems a la Carte", 2018); the steps of an
//! object and the settings that make a step invalid (PrusaSlicer, an idea
//! only). See docs/references/papers-and-algorithms.md and
//! docs/references/prusaslicer.md. The hash is wyhash (`std.hash.Wyhash`),
//! see docs/references/libraries.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const settings_mod = @import("settings.zig");
const tiers = @import("settings_tiers.zig");
const stream_mod = @import("stream.zig");
const Settings = settings_mod.Settings;

/// The key of a piece: a hash of all inputs that its stages read.
pub const Key = u64;

/// 0 is never a valid key. `KeyBuilder.final` returns `h | 1`.
pub const no_key: Key = 0;

pub const Tier = settings_mod.Tier;

pub const Lane = enum(u1) { exact, draft };

/// The kept stream of one level, with the key that made it.
pub const LevelPaths = struct {
    key: Key = no_key,
    stream: stream_mod.Stream = .{},
    /// The count of slices since the last use (for the eviction).
    age: u32 = 0,

    pub fn deinit(p: *LevelPaths, gpa: std.mem.Allocator) void {
        p.stream.deinit(gpa);
        p.* = .{};
    }

    /// True if the slot holds a complete stream for `key`.
    pub fn holds(p: *const LevelPaths, key: Key) bool {
        return key != no_key and p.key == key and p.stream.valid;
    }
};

/// The form of one level: two generations of paths. The text tier
/// (milestone M3) adds its fields here.
pub const LevelForm = struct {
    paths: [2]LevelPaths = .{ .{}, .{} },
    /// One more for each change of the paths of the level. The view makes
    /// the scene of a level again only when it changes.
    rev: u32 = 0,

    pub fn deinit(f: *LevelForm, gpa: std.mem.Allocator) void {
        for (&f.paths) |*p| p.deinit(gpa);
    }

    /// Makes the generation with `key` the current one (`paths[0]`). If
    /// no generation has it, the older one goes, the current one becomes
    /// the older one, and the current slot is empty. Returns true if a
    /// generation has the key.
    pub fn select(f: *LevelForm, gpa: std.mem.Allocator, key: Key) bool {
        if (f.paths[0].holds(key)) {
            f.paths[0].age = 0;
            f.paths[1].age +|= 1;
            return true;
        }
        if (f.paths[1].holds(key)) {
            std.mem.swap(LevelPaths, &f.paths[0], &f.paths[1]);
            f.paths[0].age = 0;
            f.paths[1].age +|= 1;
            return true;
        }
        f.paths[1].deinit(gpa);
        f.paths[1] = f.paths[0];
        f.paths[1].age +|= 1;
        f.paths[0] = .{};
        return false;
    }

    /// Stores the stream of a new plan as the current generation. The key
    /// goes in after the stream (rule 1).
    pub fn store(f: *LevelForm, gpa: std.mem.Allocator, key: Key, s: stream_mod.Stream) void {
        f.paths[0].deinit(gpa);
        f.paths[0].stream = s;
        f.paths[0].key = key;
        f.rev +%= 1;
    }
};

/// Frees each form and the slice of them.
pub fn freeForms(gpa: std.mem.Allocator, forms: []LevelForm) void {
    for (forms) |*f| f.deinit(gpa);
    gpa.free(forms);
}

/// A hash of the inputs of a piece. It reads values in a fixed order: the
/// order of the fields of a struct, of the parts, and of a list. It never
/// reads a pointer value or the bytes of padding.
pub const KeyBuilder = struct {
    h: std.hash.Wyhash,

    pub fn init(seed: u64) KeyBuilder {
        return .{ .h = .init(seed) };
    }

    /// Adds a value: a number, an enum, a text, or a list or a struct of
    /// them (see settings.hashValue).
    pub fn add(kb: *KeyBuilder, v: anytype) void {
        settings_mod.hashValue(&kb.h, v);
    }

    /// Adds each setting that `tier` reads (each setting but its skip
    /// list), in the order of the fields.
    pub fn settings(kb: *KeyBuilder, s: *const Settings, comptime tier: Tier) void {
        hashSettings(&kb.h, s, tier);
    }

    pub fn final(kb: *const KeyBuilder) Key {
        var h = kb.h;
        return h.final() | 1;
    }
};

/// Adds each setting that `tier` reads to `h`, in the order of the fields.
/// The name of the setting goes in too, so that two settings with the
/// same value in other places give other keys.
pub fn hashSettings(h: *std.hash.Wyhash, s: *const Settings, comptime tier: Tier) void {
    @setEvalBranchQuota(2_000_000);
    inline for (@typeInfo(Settings).@"struct".fields) |g| {
        inline for (@typeInfo(g.type).@"struct".fields) |f| {
            if (comptime !tiers.skips(g.name ++ "." ++ f.name, tier)) {
                h.update(g.name ++ "." ++ f.name ++ "\x00");
                settings_mod.hashValue(h, @field(@field(s, g.name), f.name));
            }
        }
    }
}

/// The key of the settings of one tier.
pub fn settingsKey(s: *const Settings, comptime tier: Tier) Key {
    var kb: KeyBuilder = .init(0xf0a3);
    kb.settings(s, tier);
    return kb.final();
}

const testing = std.testing;

/// The 11 settings of the outline key.
const geometry_names = [_][]const u8{
    "project.first_layer_height", "project.layer_height",   "filament.shrinkage_z",
    "filament.shrinkage_xy",      "filament.xy_offset",     "filament.hole_xy_offset",
    "project.first_layer_xy_offset", "project.resolution",  "engine.gap_closing",
    "project.polyholes",          "project.fast_offsets",
};

/// The app preferences: no key reads them.
const prefs = [_][]const u8{ "engine.threads", "engine.draft_slices", "engine.auto_simulate", "engine.slice_form", "engine.verify_slices", "engine.form_budget_mb" };

test "form: the geometry key reads the 11 outline settings and no other" {
    @setEvalBranchQuota(2_000_000);
    var n: usize = 0;
    inline for (@typeInfo(Settings).@"struct".fields) |g| {
        inline for (@typeInfo(g.type).@"struct".fields) |f| {
            const name = g.name ++ "." ++ f.name;
            const read = comptime !tiers.skips(name, .geometry);
            var listed = false;
            for (geometry_names) |x| listed = listed or std.mem.eql(u8, x, name);
            try testing.expectEqual(listed, read);
            n += @intFromBool(read);
        }
    }
    try testing.expectEqual(geometry_names.len, n);
}

test "form: a change of each outline setting changes the geometry key" {
    const base: Settings = .{};
    const k0 = settingsKey(&base, .geometry);
    const values = [_][]const u8{ "0.25", "0.25", "1.01", "1.01", "0.05", "0.05", "-0.05", "0.02", "2", "true", "true" };
    for (geometry_names, values) |name, v| {
        var s = base;
        try s.set(name, v);
        try testing.expect(settingsKey(&s, .geometry) != k0);
    }
    var s = base;
    try s.set("project.infill_density", "0.5");
    try testing.expectEqual(k0, settingsKey(&s, .geometry));
}

test "form: an app preference changes no key" {
    const base: Settings = .{};
    const values = [_][]const u8{ "3", "false", "false", "true", "true", "17" };
    for (prefs, values) |name, v| {
        var s = base;
        try s.set(name, v);
        inline for (.{ Tier.mesh, Tier.geometry, Tier.regions, Tier.paths, Tier.text }) |t| {
            try testing.expectEqual(settingsKey(&base, t), settingsKey(&s, t));
        }
    }
}

test "form: a patch setting changes the text key and no other key" {
    const base: Settings = .{};
    for (settings_mod.patch_settings) |name| {
        if (std.mem.eql(u8, name, "project.path_rules")) continue;
        var s = base;
        const v: []const u8 = if (std.mem.endsWith(u8, name, "_layers")) "7" else "123";
        s.set(name, v) catch continue;
        try testing.expect(settingsKey(&s, .text) != settingsKey(&base, .text));
        inline for (.{ Tier.geometry, Tier.regions, Tier.paths }) |t| {
            try testing.expectEqual(settingsKey(&base, t), settingsKey(&s, t));
        }
    }
}

test "form: equal settings give equal keys" {
    var a: Settings = .{};
    var b: Settings = .{};
    try a.set("project.wall_count", "4");
    try b.set("project.wall_count", "4");
    // A text with the same bytes at another address.
    const t1 = try testing.allocator.dupe(u8, "name");
    defer testing.allocator.free(t1);
    const t2 = try testing.allocator.dupe(u8, "name");
    defer testing.allocator.free(t2);
    a.engine.job_name = t1;
    b.engine.job_name = t2;
    inline for (.{ Tier.mesh, Tier.geometry, Tier.regions, Tier.paths, Tier.text }) |t| {
        try testing.expectEqual(settingsKey(&a, t), settingsKey(&b, t));
    }
    try testing.expect(settingsKey(&a, .paths) != no_key);
}

test "form: the generations of a level" {
    const gpa = testing.allocator;
    var f: LevelForm = .{};
    defer f.deinit(gpa);
    try testing.expect(!f.select(gpa, 5));
    f.store(gpa, 5, .{ .valid = true });
    try testing.expect(f.select(gpa, 5));
    try testing.expect(!f.select(gpa, 7));
    f.store(gpa, 7, .{ .valid = true });
    // Back to 5: the older generation.
    try testing.expect(f.select(gpa, 5));
    try testing.expectEqual(@as(Key, 5), f.paths[0].key);
    try testing.expectEqual(@as(Key, 7), f.paths[1].key);
}
