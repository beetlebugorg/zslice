//! The session of an app: all that it needs to come back exactly as it was
//! after a reload or a quit (specs: session restore). One file, the same in
//! each app:
//!
//! - project.zslice: the plates (the project file of the set, with the
//!   parts, the settings, the edits, and the printer of each plate);
//! - scene-<i>.bin: the last scene of each plate (its beads), so the view
//!   shows the last frame at once at startup, before a slice;
//! - session.json: the camera (8 floats, zs_view_get_camera);
//! - app.txt: the state of the app itself (its pages, scroll positions, the
//!   focused field...), as the app wrote it. The core keeps it as it is.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const zip = zs.zipfile;
const plate_set = @import("plate_set.zig");
const project_file = @import("project_file.zig");
const Set = plate_set.Set;

pub const format = 1;

const Json = struct {
    format: u32 = format,
    camera: ?[8]f32 = null,
};

/// The session file of the set, in gpa.
pub fn write(gpa: Allocator, set: *Set, camera: ?[8]f32, app_text: []const u8) (Allocator.Error || error{WriteFailed})![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var entries: std.ArrayList(zip.Entry) = .empty;
    const proj = try set.saveProject(a, "session");
    try entries.append(a, .{ .name = "project.zslice", .data = proj });
    for (0..set.count()) |i| {
        const sc = set.scene(i) orelse continue;
        const name = try std.fmt.allocPrint(a, "scene-{d}.bin", .{i});
        try entries.append(a, .{ .name = name, .data = try a.dupe(u8, sc) });
    }
    const json = try std.json.Stringify.valueAlloc(a, Json{ .camera = camera }, .{});
    try entries.append(a, .{ .name = "session.json", .data = json });
    try entries.append(a, .{ .name = "app.txt", .data = try a.dupe(u8, app_text) });
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try zip.write(gpa, &out.writer, entries.items);
    return out.toOwnedSlice();
}

pub const Restored = struct {
    camera: ?[8]f32,
    /// The text of the app, in gpa (the caller frees it).
    app_text: []u8,
};

pub const Error = project_file.Error || error{NotSession};

/// Puts a session back: the plates of the project replace those of the
/// set, each plate gets its last scene, and the camera and the text of the
/// app come back.
pub fn read(gpa: Allocator, bytes: []const u8, set: *Set, diag: *project_file.Diagnostic) Error!Restored {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const list = zip.readAll(a, bytes) catch return error.NotSession;
    var proj: ?[]const u8 = null;
    var json: ?[]const u8 = null;
    var app_text: []const u8 = "";
    for (list) |e| {
        if (std.mem.eql(u8, e.name, "project.zslice")) proj = e.data;
        if (std.mem.eql(u8, e.name, "session.json")) json = e.data;
        if (std.mem.eql(u8, e.name, "app.txt")) app_text = e.data;
    }
    try set.openProject(proj orelse return error.NotSession, diag);
    for (list) |e| {
        if (!std.mem.startsWith(u8, e.name, "scene-") or !std.mem.endsWith(u8, e.name, ".bin")) continue;
        const i = std.fmt.parseInt(usize, e.name[6 .. e.name.len - 4], 10) catch continue;
        try set.restoreScene(i, e.data);
    }
    // Untyped JSON: the typed reader pulls in f128 math (roundq), which
    // the GTK link does not have (see project_file.zig).
    var camera: ?[8]f32 = null;
    if (json) |j| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, j, .{}) catch null;
        if (v) |root| if (root == .object) if (root.object.get("camera")) |c| if (c == .array and c.array.items.len == 8) {
            var cam: [8]f32 = undefined;
            var ok = true;
            for (c.array.items, &cam) |x, *o| o.* = switch (x) {
                .float => |f| @floatCast(f),
                .integer => |n| @floatFromInt(n),
                else => blk: {
                    ok = false;
                    break :blk 0;
                },
            };
            if (ok) camera = cam;
        };
    }
    return .{ .camera = camera, .app_text = try gpa.dupe(u8, app_text) };
}
