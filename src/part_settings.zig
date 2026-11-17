//! The settings of each part, and the modifier volumes, for a slice.
//!
//! A part of a Cura project 3MF can have its own settings, and a part can
//! be a modifier volume (see import_cura.partSettings). Before a slice,
//! `plan` sorts the parts:
//!
//! - A modifier volume (a Cura infill mesh) does not print. It becomes a
//!   modifier of the job (see engine.Job.setModifiers and layer.Modifier),
//!   with its settings and its order. As in Cura, it has the settings of
//!   the profile and its own, and not the settings of the parts.
//! - The other volume types of Cura (cutting mesh, anti overhang mesh,
//!   support mesh) do not print either. zslice has no such volumes yet: a
//!   note says so.
//! - A part that prints can have its own settings. If all the parts that
//!   print have the same settings, the settings apply to the whole plate.
//!   Else each part slices with its own settings, as its own job (see
//!   plate_job.zig): its walls, its layer height, its infill, its
//!   support, and the rest. Only the settings of the plate (see
//!   settings.isPlateSetting) stay the same for all parts; a part
//!   setting of the plate gets a note.
//! - A modifier volume belongs to one part that prints: the part it
//!   overlaps most, if the input does not name it.
//!
//! Each Cura key that zslice does not use gets a note.
//!
//! References (see REFERENCES.md): the Cura project 3MF metadata, and the
//! infill meshes of CuraEngine (the behavior, not code).

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const settings_mod = @import("settings.zig");
const import_cura = @import("import_cura.zig");
const threemf = @import("threemf.zig");
const engine = @import("engine.zig");
const Mesh = mesh_mod.Mesh;
const Change = settings_mod.Change;

pub const Role = import_cura.PartRole;

/// One part of the plate for `plan`.
pub const Input = struct {
    name: []const u8,
    meta: []const threemf.Meta,
    /// The mesh of the part on the bed, in the coordinates of the plate.
    mesh: ?*const Mesh,
    /// For a volume: the index of the input of its part, or null (then
    /// the part that it overlaps most).
    host: ?usize = null,
};

/// The settings of one part that prints.
pub const PartPlan = struct {
    /// The index of the part in the inputs.
    input: usize,
    /// The changes of the part over the settings of the plate.
    changes: []const Change = &.{},
    /// The modifier volumes of the part. Their meshes are the meshes of
    /// the inputs.
    modifiers: []const engine.Job.ModifierInput = &.{},
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    /// The settings for the whole plate.
    base: []const Change = &.{},
    /// The parts that print, in the order of the inputs.
    parts: []const PartPlan = &.{},
    /// One line for each note.
    notes: []const []const u8 = &.{},

    /// The plan of the part of input `input`, or null.
    pub fn partOf(self: *const Plan, input: usize) ?*const PartPlan {
        for (self.parts) |*p| if (p.input == input) return p;
        return null;
    }

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }

    /// Applies `base` to `s`. A change that zslice refuses gets a note.
    pub fn applyBase(self: *Plan, s: *settings_mod.Settings) Allocator.Error!void {
        var notes: std.ArrayList([]const u8) = .fromOwnedSlice(@constCast(self.notes));
        const a = self.arena.allocator();
        for (self.base) |c| s.set(c.name, c.value) catch |e| {
            try notes.append(a, try std.fmt.allocPrint(a, "{s} = {s}: {s}", .{ c.name, c.value, @errorName(e) }));
        };
        self.notes = notes.items;
    }
};

/// True if the part prints (its role is `normal`).
pub fn prints(meta: []const threemf.Meta) bool {
    return import_cura.partRole(meta).role == .normal;
}

/// The name of a role for a note.
pub fn roleName(role: Role) []const u8 {
    return switch (role) {
        .normal => "a part",
        .infill_mesh => "a modifier volume (Cura infill mesh)",
        .cutting_mesh => "a cutting mesh",
        .anti_overhang_mesh => "an anti overhang mesh",
        .support_mesh => "a support mesh",
    };
}

pub fn plan(gpa: Allocator, inputs: []const Input, settings: *const settings_mod.Settings) Allocator.Error!Plan {
    var out: Plan = .{ .arena = .init(gpa) };
    errdefer out.deinit();
    const a = out.arena.allocator();
    var notes: std.ArrayList([]const u8) = .empty;
    const ps = try a.alloc(import_cura.PartSettings, inputs.len);
    for (inputs, ps) |in, *p| {
        p.* = try import_cura.partSettings(a, in.meta, settings);
        for (p.ignored) |ig| try notes.append(a, try std.fmt.allocPrint(a, "{s}: {s} = {s} is not used: {s}", .{ in.name, ig.key, ig.value, ig.why }));
    }

    // The settings of the parts that print: the same for all, or not.
    var first: ?usize = null;
    var same = true;
    for (ps, 0..) |p, k| {
        if (p.role != .normal) continue;
        if (first) |f| {
            if (!sameChanges(ps[f].sets, p.sets)) same = false;
        } else first = k;
    }
    if (first) |f| if (same) {
        out.base = ps[f].sets;
    };

    // The parts that print, with their own changes.
    var parts: std.ArrayList(PartPlan) = .empty;
    for (inputs, ps, 0..) |in, p, k| {
        if (p.role != .normal) continue;
        var list: std.ArrayList(Change) = .empty;
        if (!same) for (p.sets) |c| {
            if (settings_mod.isPlateSetting(c.name)) {
                try notes.append(a, try std.fmt.allocPrint(a, "{s}: {s} = {s} is not used: the parts have different settings, and this setting is the same for all parts of the plate", .{ in.name, c.name, c.value }));
                continue;
            }
            try list.append(a, c);
        };
        try parts.append(a, .{ .input = k, .changes = list.items });
    }

    // The modifier volumes, each on its part.
    const mods = try a.alloc(std.ArrayList(engine.Job.ModifierInput), parts.items.len);
    @memset(mods, .empty);
    for (inputs, ps) |in, p| {
        switch (p.role) {
            .normal => {},
            .infill_mesh => {
                const mesh = in.mesh orelse continue;
                const host = hostOf(inputs, parts.items, in) orelse {
                    try notes.append(a, try std.fmt.allocPrint(a, "{s}: the modifier volume has no part to change", .{in.name}));
                    continue;
                };
                // As in Cura, a modifier volume has the settings of the
                // profile and its own: the settings of the plate from the
                // parts (`base`) and of its part do not apply to it.
                var list: std.ArrayList(Change) = .empty;
                for ([_][]const Change{ out.base, parts.items[host].changes }) |set| for (set) |c| {
                    const own = for (p.sets) |o| {
                        if (std.mem.eql(u8, o.name, c.name)) break true;
                    } else false;
                    if (own) continue;
                    var w: std.Io.Writer.Allocating = .init(a);
                    @import("app.zig").App.writeSettingOf(settings.*, c.name, &w.writer) catch continue;
                    try list.append(a, .{ .name = c.name, .value = w.written() });
                };
                try list.appendSlice(a, p.sets);
                try mods[host].append(a, .{ .mesh = mesh, .changes = list.items, .order = p.order, .name = in.name });
            },
            else => try notes.append(a, try std.fmt.allocPrint(a, "{s}: {s} does not print: zslice has no such volume yet", .{ in.name, roleName(p.role) })),
        }
    }
    for (parts.items, mods) |*pp, m| pp.modifiers = m.items;
    out.parts = parts.items;
    out.notes = notes.items;
    return out;
}

/// The index in `parts` of the part of volume `in`: its host, or the part
/// whose box overlaps the box of the volume most.
fn hostOf(inputs: []const Input, parts: []const PartPlan, in: Input) ?usize {
    if (in.host) |h| {
        for (parts, 0..) |p, k| if (p.input == h) return k;
        return null;
    }
    const vm = in.mesh orelse return null;
    const vb = vm.bounds();
    var best: ?usize = null;
    var best_v: f64 = -1;
    for (parts, 0..) |p, k| {
        const qm = inputs[p.input].mesh orelse continue;
        const qb = qm.bounds();
        var vol: f64 = 1;
        for (0..3) |d| vol *= @max(0, @min(vb.max[d], qb.max[d]) - @max(vb.min[d], qb.min[d]));
        if (vol > best_v) {
            best_v = vol;
            best = k;
        }
    }
    return best;
}

fn sameChanges(x: []const Change, y: []const Change) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (!std.mem.eql(u8, p.name, q.name) or !std.mem.eql(u8, p.value, q.value)) return false;
    }
    return true;
}

/// One line for each setting of a part, for a part page: the Cura key,
/// its value, and the zslice setting it becomes (or why it is not used).
/// The result goes in `a`.
pub fn describe(a: Allocator, meta: []const threemf.Meta, settings: *const settings_mod.Settings) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    const ps = try import_cura.partSettings(a, meta, settings);
    if (ps.role != .normal) {
        try lines.append(a, try std.fmt.allocPrint(a, "This is {s}. It does not print.", .{roleName(ps.role)}));
        if (ps.role == .infill_mesh) try lines.append(a, try std.fmt.allocPrint(a, "Order {d}: where modifiers overlap, the higher order wins.", .{ps.order}));
    }
    for (ps.sets) |c| try lines.append(a, try std.fmt.allocPrint(a, "{s} = {s}", .{ c.name, c.value }));
    for (ps.ignored) |ig| try lines.append(a, try std.fmt.allocPrint(a, "{s} = {s}: not used, {s}", .{ ig.key, ig.value, ig.why }));
    return lines.items;
}

const testing = std.testing;

fn box(gpa: Allocator, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) !Mesh {
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, x0, y0, z0, x1, y1, z1);
    return b.finish();
}

fn testMeta(comptime list: []const [2][]const u8) [list.len]threemf.Meta {
    var out: [list.len]threemf.Meta = undefined;
    for (list, &out) |kv, *m| m.* = .{ .key = @constCast(kv[0]), .value = @constCast(kv[1]) };
    return out;
}

test "part settings: a modifier volume, and the same settings on all parts" {
    const gpa = testing.allocator;
    var plate = try box(gpa, 0, 0, 0, 40, 40, 3);
    defer plate.deinit(gpa);
    var window = try box(gpa, 10, 10, 0, 30, 30, 3);
    defer window.deinit(gpa);
    const plate_meta = testMeta(&.{.{ "cura:infill_sparse_density", "=100" }});
    const window_meta = testMeta(&.{ .{ "cura:infill_mesh", "=True" }, .{ "cura:wall_line_count", "=0" }, .{ "cura:infill_wipe_dist", "=2" } });
    const cut_meta = testMeta(&.{.{ "cura:cutting_mesh", "True" }});
    const inputs = [_]Input{
        .{ .name = "plate", .meta = &plate_meta, .mesh = &plate },
        .{ .name = "window", .meta = &window_meta, .mesh = &window },
        .{ .name = "cut", .meta = &cut_meta, .mesh = &window },
    };
    const s: settings_mod.Settings = .{};
    var p = try plan(gpa, &inputs, &s);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.base.len);
    try testing.expectEqualStrings("project.infill_density", p.base[0].name);
    // One part prints, and the window is its modifier.
    try testing.expectEqual(@as(usize, 1), p.parts.len);
    const mods = p.parts[0].modifiers;
    try testing.expectEqual(@as(usize, 1), mods.len);
    try testing.expectEqualStrings("window", mods[0].name);
    // The window has the density of the profile, and its own settings.
    try testing.expectEqualStrings("project.infill_density", mods[0].changes[0].name);
    try testing.expectEqualStrings("0.2", mods[0].changes[0].value);
    // The wipe distance and the cutting mesh get notes.
    try testing.expectEqual(@as(usize, 2), p.notes.len);
    var s2 = s;
    try p.applyBase(&s2);
    try testing.expectEqual(@as(f64, 1), s2.project.infill_density);
    try testing.expect(!prints(&window_meta));
    try testing.expect(prints(&plate_meta));
    const lines = try describe(p.arena.allocator(), &window_meta, &s);
    try testing.expect(lines.len >= 3);
}

test "part settings: parts with different settings keep them" {
    const gpa = testing.allocator;
    var m1 = try box(gpa, 0, 0, 0, 10, 10, 3);
    defer m1.deinit(gpa);
    var m2 = try box(gpa, 20, 0, 0, 30, 10, 3);
    defer m2.deinit(gpa);
    const a_meta = testMeta(&.{ .{ "cura:infill_sparse_density", "50" }, .{ "cura:wall_line_count", "4" }, .{ "cura:material_print_temperature", "230" } });
    const inputs = [_]Input{
        .{ .name = "a", .meta = &a_meta, .mesh = &m1 },
        .{ .name = "b", .meta = &.{}, .mesh = &m2 },
    };
    const s: settings_mod.Settings = .{};
    var p = try plan(gpa, &inputs, &s);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.base.len);
    try testing.expectEqual(@as(usize, 2), p.parts.len);
    // Part a keeps its walls and its infill; the nozzle temperature is
    // the same for all parts, so it gets a note.
    const ch = p.parts[0].changes;
    var walls = false;
    var temp = false;
    for (ch) |c| {
        walls = walls or std.mem.eql(u8, c.name, "project.wall_count");
        temp = temp or std.mem.eql(u8, c.name, "filament.nozzle_temp");
    }
    try testing.expect(walls);
    try testing.expect(!temp);
    try testing.expectEqual(@as(usize, 0), p.parts[1].changes.len);
}
