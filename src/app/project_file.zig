//! The project file of zslice: all plates of a plate set in one file
//! (".3mf"), with the parts, their places and settings, and the printer,
//! the filament, and the print settings of each plate.
//!
//! The file is a 3MF file. Its model (3D/3dmodel.model) is the first plate
//! with parts, so another slicer opens that plate. zslice also keeps:
//!
//! - Metadata/zslice_project.json: the format (1), the name, the active
//!   plate, and for each plate its name, its file, and its three settings
//!   texts (the machine, the filament, and the project group, as
//!   zs_app_state_write writes them).
//! - Metadata/zslice_plate_<n>.3mf: the 3MF file of plate n (the app's
//!   own 3MF, with its parts, its overrides, and its layer profiles), or
//!   no file for an empty plate.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = @import("../app.zig").App;
const zip = zs.zipfile;

pub const format = 1;
const index_name = "Metadata/zslice_project.json";

pub const Error = Allocator.Error || error{ NotProject, BadProject };

pub const Diagnostic = struct { message: []const u8 = "" };

/// A plate to save.
pub const PlateIn = struct { app: *App, name: []const u8 };

const PlateJson = struct {
    name: []const u8 = "",
    file: []const u8 = "",
    machine: []const u8 = "",
    filament: []const u8 = "",
    project: []const u8 = "",
};

const IndexJson = struct {
    format: u32 = format,
    name: []const u8 = "",
    active: usize = 0,
    plates: []const PlateJson = &.{},
};

fn stateText(gpa: Allocator, app: *const App, g: zs.profile.Group) (Allocator.Error || error{WriteFailed})![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try app.writeState(g, &aw.writer);
    return aw.toOwnedSlice();
}

/// The project file of the plates, in gpa.
pub fn save(gpa: Allocator, name: []const u8, plates: []const PlateIn, active: usize) (Allocator.Error || error{WriteFailed})![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var entries: std.ArrayList(zip.Entry) = .empty;
    var index: std.ArrayList(PlateJson) = .empty;
    var base_done = false;
    for (plates, 0..) |p, n| {
        var pj: PlateJson = .{
            .name = p.name,
            .machine = try stateText(a, p.app, .machine),
            .filament = try stateText(a, p.app, .filament),
            .project = try stateText(a, p.app, .project),
        };
        if (p.app.plate.count() > 0) {
            const bytes = p.app.write3mfAlloc(a) catch |e| switch (e) {
                error.NoModel => null,
                else => |x| return x,
            };
            if (bytes) |b| {
                pj.file = try std.fmt.allocPrint(a, "Metadata/zslice_plate_{d}.3mf", .{n + 1});
                try entries.append(a, .{ .name = pj.file, .data = b });
                // The first plate with parts is the model of the file.
                if (!base_done) {
                    const inner = zip.readAll(a, b) catch null;
                    if (inner) |list| for (list) |e| try entries.append(a, e);
                    base_done = inner != null;
                }
            }
        }
        try index.append(a, pj);
    }
    const json = try std.json.Stringify.valueAlloc(a, IndexJson{ .name = name, .active = active, .plates = index.items }, .{ .whitespace = .indent_1 });
    try entries.append(a, .{ .name = index_name, .data = json });
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try zip.write(gpa, &out.writer, entries.items);
    return out.toOwnedSlice();
}

/// A plate to open.
pub const PlateOut = struct {
    name: []const u8,
    machine: []const u8,
    filament: []const u8,
    project: []const u8,
    /// The 3MF file of the plate, or empty.
    model: []const u8,
};

pub const Parsed = struct { name: []const u8, active: usize, plates: []PlateOut };

/// True if the bytes are a project file of zslice.
pub fn isProject(gpa: Allocator, bytes: []const u8) bool {
    const list = zip.readAll(gpa, bytes) catch return false;
    defer zip.freeAll(gpa, list);
    for (list) |e| if (std.mem.eql(u8, e.name, index_name)) return true;
    return false;
}

/// Reads a project file, in `arena`.
pub fn parse(arena: Allocator, bytes: []const u8, diag: *Diagnostic) Error!Parsed {
    const list = zip.readAll(arena, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotProject,
    };
    const find = struct {
        fn f(l: []const zip.Entry, name: []const u8) ?[]const u8 {
            for (l) |e| if (std.mem.eql(u8, e.name, name)) return e.data;
            return null;
        }
    }.f;
    const text = find(list, index_name) orelse return error.NotProject;
    // The untyped reader: the typed one needs 128-bit floats, which the
    // C library of a GTK link does not have.
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        diag.message = "The index of the project does not read.";
        return error.BadProject;
    };
    if (root != .object) return error.BadProject;
    const num = struct {
        fn f(v: ?std.json.Value) usize {
            const x = v orelse return 0;
            return switch (x) {
                .integer => |i| if (i > 0) @intCast(i) else 0,
                else => 0,
            };
        }
    }.f;
    const str = struct {
        fn f(o: std.json.ObjectMap, k: []const u8) []const u8 {
            const x = o.get(k) orelse return "";
            return if (x == .string) x.string else "";
        }
    }.f;
    if (num(root.object.get("format")) > format) {
        diag.message = "The project is from a newer zslice.";
        return error.BadProject;
    }
    const list_v = root.object.get("plates") orelse return error.BadProject;
    if (list_v != .array) return error.BadProject;
    const out = try arena.alloc(PlateOut, list_v.array.items.len);
    for (list_v.array.items, out) |pv, *o| {
        if (pv != .object) return error.BadProject;
        const file = str(pv.object, "file");
        o.* = .{
            .name = str(pv.object, "name"),
            .machine = str(pv.object, "machine"),
            .filament = str(pv.object, "filament"),
            .project = str(pv.object, "project"),
            .model = if (file.len > 0) find(list, file) orelse "" else "",
        };
    }
    const idx = .{ .name = str(root.object, "name"), .active = num(root.object.get("active")) };
    return .{ .name = idx.name, .active = idx.active, .plates = out };
}

/// Puts a plate of a project on an app: its settings, then its parts. A
/// group that does not apply keeps the defaults, and says so in diag.
pub fn loadPlate(app: *App, p: PlateOut, diag: *Diagnostic) Allocator.Error!void {
    const groups = [_]zs.profile.Group{ .machine, .filament, .project };
    const texts = [_][]const u8{ p.machine, p.filament, p.project };
    for (groups, texts) |g, t| {
        app.resetGroup(g);
        if (t.len == 0) continue;
        var pd: zs.profile.Diagnostic = .{};
        app.applyProfile(g, "saved", t, &pd) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                app.resetGroup(g);
                diag.message = "A settings group of a plate did not apply; it has the defaults.";
            },
        };
    }
    if (p.model.len > 0) app.loadStl(p.name, p.model) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => diag.message = "The parts of a plate did not load.",
    };
}

const testing = std.testing;

test "project file: plates, settings, and parts come back" {
    const gpa = testing.allocator;
    const a1 = try App.create(gpa, null, null);
    defer a1.destroy();
    const a2 = try App.create(gpa, null, null);
    defer a2.destroy();
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var m = try b.finish();
    defer m.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    try a1.loadStl("box", stl.written());
    try a1.setSetting("project.infill_density", "0.4");
    try a2.setSetting("machine.bed_size_x", "300");
    const bytes = try save(gpa, "test", &.{ .{ .app = a1, .name = "Boxes" }, .{ .app = a2, .name = "" } }, 1);
    defer gpa.free(bytes);
    try testing.expect(isProject(gpa, bytes));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const parsed = try parse(arena_state.allocator(), bytes, &diag);
    try testing.expectEqual(@as(usize, 2), parsed.plates.len);
    try testing.expectEqual(@as(usize, 1), parsed.active);
    try testing.expectEqualStrings("Boxes", parsed.plates[0].name);
    const b1 = try App.create(gpa, null, null);
    defer b1.destroy();
    const b2 = try App.create(gpa, null, null);
    defer b2.destroy();
    try loadPlate(b1, parsed.plates[0], &diag);
    try loadPlate(b2, parsed.plates[1], &diag);
    try testing.expectEqualStrings("", diag.message);
    try testing.expectEqual(@as(usize, 1), b1.plate.count());
    try testing.expectEqual(@as(f64, 0.4), b1.settings.project.infill_density);
    try testing.expectEqual(@as(f64, 300), b2.settings.machine.bed_size_x);
    try testing.expectEqual(@as(usize, 0), b2.plate.count());
    // A plain 3MF of one plate is no project.
    const plain = try a1.write3mfAlloc(gpa);
    defer gpa.free(plain);
    try testing.expect(!isProject(gpa, plain));
}
