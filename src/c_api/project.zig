//! The C API of printdeck.yml projects (src/project.zig). The results are
//! JSON texts, with the buffer rules of zs_app_setting_get: call once
//! with buf NULL for the length, then again with a buffer.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const ok = c.ok;
const gpa = c.gpa;
const App = zs.app.App;
const project = zs.project;
const Writer = std.Io.Writer;

export fn zs_files_new() ?*project.Files {
    const f = gpa.create(project.Files) catch return null;
    f.* = .init(gpa);
    return f;
}

export fn zs_files_free(f: ?*project.Files) void {
    const files = f orelse return;
    files.deinit();
    gpa.destroy(files);
}

/// Adds a file of the repository (path relative to it).
export fn zs_files_add(f: ?*project.Files, path: ?[*:0]const u8, data: ?[*]const u8, len: usize) c_int {
    const files = f orelse return @intFromEnum(Status.invalid_argument);
    const p = std.mem.span(path orelse return @intFromEnum(Status.invalid_argument));
    const d: []const u8 = if (len == 0) "" else (data orelse return @intFromEnum(Status.invalid_argument))[0..len];
    files.add(p, d) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

fn copyOut(text: []const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The choices of the parts: "count,count,..." with one entry for each
/// part. "-" (or a missing entry) is the count of printdeck.yml, 0 leaves
/// the part out.
fn choicesOf(arena: std.mem.Allocator, text: []const u8, n: usize) ![]project.Choice {
    const out = try arena.alloc(project.Choice, n);
    @memset(out, .{});
    var it = std.mem.splitScalar(u8, text, ',');
    var i: usize = 0;
    while (it.next()) |t0| : (i += 1) {
        if (i >= n) break;
        const t = std.mem.trim(u8, t0, " ");
        if (t.len == 0 or std.mem.eql(u8, t, "-")) continue;
        const count = std.fmt.parseInt(u32, t, 10) catch continue;
        out[i] = .{ .on = count > 0, .count = count };
    }
    return out;
}

const Planned = struct {
    project: project.Project,
    plates: []const project.Plate,
};

fn planOf(arena: std.mem.Allocator, text: []const u8, counts: []const u8, diag: *project.Diagnostic) !Planned {
    const p = try project.parse(arena, text, diag);
    const plates = try project.plan(arena, &p, try choicesOf(arena, counts, p.parts.len));
    return .{ .project = p, .plates = plates };
}

fn errorJson(arena: std.mem.Allocator, diag: project.Diagnostic, e: anyerror) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .@"error" = if (diag.message.len > 0) diag.message else @errorName(e),
        .line = diag.line,
    }, .{});
}

/// The parts and the suggested plates of a printdeck.yml, as JSON:
///   {"name", "parts": [{"name", "base_name", "variant", "group",
///    "description", "files", "count", "printer", "profile", "material",
///    "settings": [{"key", "value"}], "alone", "prebuilt"}],
///    "plates": [{"printer", "profile", "material",
///    "items": [{"part", "count"}]}]}
/// or {"error", "line"}. counts: see choicesOf (NULL: all parts).
export fn zs_project_plan(text: ?[*:0]const u8, counts: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const t = std.mem.span(text orelse return @intFromEnum(Status.invalid_argument));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: project.Diagnostic = .{};
    const json = blk: {
        const planned = planOf(arena, t, if (counts) |cs| std.mem.span(cs) else "", &diag) catch |e|
            break :blk errorJson(arena, diag, e) catch return @intFromEnum(Status.out_of_memory);
        break :blk std.json.Stringify.valueAlloc(arena, .{
            .name = planned.project.name,
            .parts = planned.project.parts,
            .plates = planned.plates,
        }, .{}) catch return @intFromEnum(Status.out_of_memory);
    };
    return copyOut(json, buf, cap, out_len);
}

/// The profiles of plate `plate` (project.plateProfiles), as JSON:
///   {"machine": {"name", "text"}, "filament": {...}, "project": {...}}
/// or {"error", "line"}. Load them, then call zs_app_project_load.
export fn zs_project_profiles(files: ?*const project.Files, text: ?[*:0]const u8, counts: ?[*:0]const u8, plate: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const f = files orelse return @intFromEnum(Status.invalid_argument);
    const t = std.mem.span(text orelse return @intFromEnum(Status.invalid_argument));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: project.Diagnostic = .{};
    const json = blk: {
        const planned = planOf(arena, t, if (counts) |cs| std.mem.span(cs) else "", &diag) catch |e|
            break :blk errorJson(arena, diag, e) catch return @intFromEnum(Status.out_of_memory);
        if (plate >= planned.plates.len) return @intFromEnum(Status.out_of_range);
        const ps = project.plateProfiles(arena, f, planned.plates[plate], &diag) catch |e|
            break :blk errorJson(arena, diag, e) catch return @intFromEnum(Status.out_of_memory);
        const P = struct { name: []const u8, text: []const u8 };
        break :blk std.json.Stringify.valueAlloc(arena, .{
            .machine = P{ .name = ps[0].name, .text = ps[0].text },
            .filament = P{ .name = ps[1].name, .text = ps[1].text },
            .project = P{ .name = ps[2].name, .text = ps[2].text },
        }, .{}) catch return @intFromEnum(Status.out_of_memory);
    };
    return copyOut(json, buf, cap, out_len);
}

/// Puts plate `plate` on the plate of the app, in place of its parts: the
/// settings of the plate (support, adhesion) as changes of the print, then
/// the copies of the files of its parts, arranged. Load the profiles of
/// zs_project_profiles first. Returns ZS_OUT_OF_RANGE if the parts do not
/// all fit on the bed (they stay on the plate). On an error, message (can
/// be NULL) gets the reason.
export fn zs_app_project_load(a: ?*App, files: ?*const project.Files, text: ?[*:0]const u8, counts: ?[*:0]const u8, plate: usize, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const f = files orelse return @intFromEnum(Status.invalid_argument);
    const t = std.mem.span(text orelse return @intFromEnum(Status.invalid_argument));
    // For the undo list: the settings and the plate change, also on an
    // error.
    defer app.undo.note(app.gpa, null, true);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: project.Diagnostic = .{};
    const say = struct {
        fn put(m: ?[*]u8, n: usize, text_: []const u8) void {
            const mm = m orelse return;
            if (n == 0) return;
            const k = @min(text_.len, n - 1);
            @memcpy(mm[0..k], text_[0..k]);
            mm[k] = 0;
        }
    }.put;
    const run = struct {
        fn go(ar: std.mem.Allocator, ap: *App, fs: *const project.Files, tx: []const u8, cs: []const u8, pl: usize, d: *project.Diagnostic) !bool {
            const planned = try planOf(ar, tx, cs, d);
            if (pl >= planned.plates.len) return error.OutOfRange;
            const p = planned.plates[pl];
            const sets = try project.plateSettings(ar, &planned.project, p, &ap.settings, d);
            for (sets) |s| ap.setSetting(s.name, s.value) catch |e| {
                d.* = .{ .message = try std.fmt.allocPrint(ar, "{s} = {s}: {s}", .{ s.name, s.value, @errorName(e) }) };
                return e;
            };
            return project.addParts(ar, ap, fs, &planned.project, p, d);
        }
    }.go;
    const fits = run(arena, app, f, t, if (counts) |cs| std.mem.span(cs) else "", plate, &diag) catch |e| {
        say(message, cap, if (diag.message.len > 0) diag.message else @errorName(e));
        return switch (e) {
            error.OutOfMemory => @intFromEnum(Status.out_of_memory),
            error.OutOfRange => @intFromEnum(Status.out_of_range),
            error.BadModel => @intFromEnum(Status.invalid_mesh),
            else => @intFromEnum(Status.invalid_value),
        };
    };
    if (!fits) {
        say(message, cap, "The parts do not all fit on the bed. Print fewer copies, or put some parts on another plate.");
        return @intFromEnum(Status.out_of_range);
    }
    say(message, cap, "");
    return ok;
}
