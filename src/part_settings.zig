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
//!   Else each part with settings becomes a modifier of its own volume,
//!   below all the modifier volumes. Such a modifier changes the infill
//!   and the skin of the part; its walls stay the walls of the plate.
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
const support_mod = @import("support.zig");
const Mesh = mesh_mod.Mesh;
const Change = settings_mod.Change;

pub const Role = import_cura.PartRole;

/// One part of the plate for `plan`.
pub const Input = struct {
    name: []const u8,
    meta: []const threemf.Meta,
    /// The mesh of the part on the bed, in the coordinates of the mesh of
    /// the job. Null for a part with no metadata (`plan` does not need
    /// it).
    mesh: ?*const Mesh,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    /// The settings for the whole plate.
    base: []const Change = &.{},
    /// The modifiers of the job. Their meshes are the meshes of the
    /// inputs.
    modifiers: []const engine.Job.ModifierInput = &.{},
    /// One line for each note.
    notes: []const []const u8 = &.{},
    /// The support of the parts with their own `project.support`: a box
    /// mark around each (support.Mark area_on or area_off).
    marks: []const support_mod.Mark = &.{},

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

/// The order of the modifiers made from the settings of a part: below
/// all modifier volumes.
const part_order: i32 = std.math.minInt(i32);

pub fn plan(gpa: Allocator, inputs: []const Input, settings: *const settings_mod.Settings) Allocator.Error!Plan {
    var out: Plan = .{ .arena = .init(gpa) };
    errdefer out.deinit();
    const a = out.arena.allocator();
    var notes: std.ArrayList([]const u8) = .empty;
    var mods: std.ArrayList(engine.Job.ModifierInput) = .empty;
    const parts = try a.alloc(import_cura.PartSettings, inputs.len);
    var marks: std.ArrayList(support_mod.Mark) = .empty;
    for (inputs, parts) |in, *ps| {
        ps.* = try import_cura.partSettings(a, in.meta, settings);
        for (ps.ignored) |ig| try notes.append(a, try std.fmt.allocPrint(a, "{s}: {s} = {s} is not used: {s}", .{ in.name, ig.key, ig.value, ig.why }));
        // The support of a part: a box mark around it, not a change of the
        // plate or a modifier (support is for the whole plate).
        if (ps.role != .normal) continue;
        var rest: std.ArrayList(Change) = .empty;
        for (ps.sets) |c| {
            if (!std.mem.eql(u8, c.name, "project.support")) {
                try rest.append(a, c);
                continue;
            }
            const mesh = in.mesh orelse continue;
            const b = mesh.bounds();
            // 1 mm more on each side: the support reaches past the part.
            try marks.append(a, .{
                .x = (b.min[0] + b.max[0]) / 2,
                .y = (b.min[1] + b.max[1]) / 2,
                .z = 0,
                .hw = (b.max[0] - b.min[0]) / 2 + 1,
                .hh = (b.max[1] - b.min[1]) / 2 + 1,
                .kind = if (std.mem.eql(u8, c.value, "off")) .area_off else .area_on,
            });
        }
        ps.sets = rest.items;
    }

    // The settings of the parts that print: the same for all, or not.
    var first: ?usize = null;
    var same = true;
    for (inputs, parts, 0..) |in, ps, k| {
        _ = in;
        if (ps.role != .normal) continue;
        if (first) |f| {
            if (!sameChanges(parts[f].sets, ps.sets)) same = false;
        } else first = k;
    }
    if (first) |f| if (same) {
        out.base = parts[f].sets;
    };

    for (inputs, parts) |in, ps| {
        switch (ps.role) {
            .normal => {
                if (same or ps.sets.len == 0) continue;
                const mesh = in.mesh orelse continue;
                // Only the infill and the skin: the walls of the plate stay.
                var list: std.ArrayList(Change) = .empty;
                for (ps.sets) |c| {
                    if (std.mem.startsWith(u8, c.name, "project.wall_")) {
                        try notes.append(a, try std.fmt.allocPrint(a, "{s}: {s} = {s} is not used: the parts have different settings, and a part keeps the walls of the plate", .{ in.name, c.name, c.value }));
                        continue;
                    }
                    try list.append(a, c);
                }
                try list.append(a, .{ .name = "project.wall_count", .value = "0" });
                try list.append(a, .{ .name = "project.wall_thickness", .value = "0" });
                try mods.append(a, .{ .mesh = mesh, .changes = list.items, .order = part_order, .name = in.name });
            },
            .infill_mesh => {
                const mesh = in.mesh orelse continue;
                // As in Cura, a modifier volume has the settings of the
                // profile and its own: the settings of the parts that
                // apply to the whole plate (`base`) do not apply to it.
                var list: std.ArrayList(Change) = .empty;
                for (out.base) |c| {
                    const own = for (ps.sets) |o| {
                        if (std.mem.eql(u8, o.name, c.name)) break true;
                    } else false;
                    if (own) continue;
                    var w: std.Io.Writer.Allocating = .init(a);
                    @import("app.zig").App.writeSettingOf(settings.*, c.name, &w.writer) catch continue;
                    try list.append(a, .{ .name = c.name, .value = w.written() });
                }
                try list.appendSlice(a, ps.sets);
                try mods.append(a, .{ .mesh = mesh, .changes = list.items, .order = ps.order, .name = in.name });
            },
            else => try notes.append(a, try std.fmt.allocPrint(a, "{s}: {s} does not print: zslice has no such volume yet", .{ in.name, roleName(ps.role) })),
        }
    }
    out.modifiers = mods.items;
    out.marks = marks.items;
    out.notes = notes.items;
    return out;
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
    try testing.expectEqual(@as(usize, 1), p.modifiers.len);
    try testing.expectEqualStrings("window", p.modifiers[0].name);
    // The window has the density of the profile, and its own settings.
    try testing.expectEqualStrings("project.infill_density", p.modifiers[0].changes[0].name);
    try testing.expectEqualStrings("0.2", p.modifiers[0].changes[0].value);
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

test "part settings: parts with different settings become modifiers" {
    const gpa = testing.allocator;
    var m1 = try box(gpa, 0, 0, 0, 10, 10, 3);
    defer m1.deinit(gpa);
    var m2 = try box(gpa, 20, 0, 0, 30, 10, 3);
    defer m2.deinit(gpa);
    const a_meta = testMeta(&.{ .{ "cura:infill_sparse_density", "50" }, .{ "cura:wall_line_count", "4" } });
    const inputs = [_]Input{
        .{ .name = "a", .meta = &a_meta, .mesh = &m1 },
        .{ .name = "b", .meta = &.{}, .mesh = null },
    };
    const s: settings_mod.Settings = .{};
    var p = try plan(gpa, &inputs, &s);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.base.len);
    try testing.expectEqual(@as(usize, 1), p.modifiers.len);
    try testing.expectEqual(std.math.minInt(i32), p.modifiers[0].order);
    // The wall count of the part is not used (wall_count and
    // wall_thickness).
    try testing.expectEqual(@as(usize, 2), p.notes.len);
}
