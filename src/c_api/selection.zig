//! The C API of the selection model, the `zs_sel_*` functions of
//! `include/zslice-app.h`. See src/app/selection.zig. The rules of the API
//! are in c_api.zig.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const ok = c.ok;
const gpa = c.gpa;
const App = zs.app.App;
const Set = zs.app.plate_set.Set;
const sel_mod = zs.app.selection;
const Selection = sel_mod.Selection;
const PartBox = sel_mod.PartBox;
const View = @import("view.zig").view_mod.View;
/// A build with no renderer has an opaque View.
const has_view = @typeInfo(View) != .@"opaque";

const bad: c_int = @intFromEnum(Status.invalid_argument);
const no_memory: c_int = @intFromEnum(Status.out_of_memory);

fn boxOf(p: *const zs.plate.Part) PartBox {
    const f = p.footprint();
    return .{ .id = p.id, .x0 = f[0], .y0 = f[1], .z0 = p.z, .x1 = f[2], .y1 = f[3], .z1 = p.z + p.height };
}

export fn zs_app_part_id(a: ?*const App, i: usize) u64 {
    const app = a orelse return 0;
    if (i >= app.plate.count()) return 0;
    return app.plate.parts.items[i].id;
}

export fn zs_app_part_index(a: ?*const App, id: u64) isize {
    const app = a orelse return -1;
    const i = app.plate.indexOfId(id) orelse return -1;
    return @intCast(i);
}

export fn zs_app_sel_parts(a: ?*const App, out: ?[*]PartBox, cap: usize, n: ?*usize) c_int {
    const app = a orelse return bad;
    const count = n orelse return bad;
    count.* = app.plate.count();
    if (out) |o| for (app.plate.parts.items[0..@min(cap, count.*)], 0..) |*p, i| {
        o[i] = boxOf(p);
    };
    return ok;
}

export fn zs_app_path_of_key(a: ?*const App, key: u64) isize {
    const app = a orelse return -1;
    if (key == 0) return -1;
    const t = app.allToolpaths() orelse return -1;
    const i = std.mem.indexOfScalar(u64, t.path_key.items, key) orelse return -1;
    return @intCast(i);
}

export fn zs_view_path_part(view: ?*const View, path: usize) isize {
    if (!has_view) return -1;
    const v = view orelse return -1;
    if (path >= v.path_part.items.len) return -1;
    const part = v.path_part.items[path];
    if (part == zs.layer.LayerPlan.no_part) return -1;
    return @intCast(part);
}

export fn zs_sel_new(out: ?*?*Selection) c_int {
    const o = out orelse return bad;
    const s = gpa.create(Selection) catch return no_memory;
    s.* = .{ .gpa = gpa };
    o.* = s;
    return ok;
}

export fn zs_sel_free(sel: ?*Selection) void {
    const s = sel orelse return;
    s.deinit();
    gpa.destroy(s);
}

export fn zs_sel_generation(sel: ?*const Selection) u64 {
    return if (sel) |s| s.gen else 0;
}

export fn zs_sel_set_parts(sel: ?*Selection, parts: ?[*]const PartBox, n: usize) c_int {
    const s = sel orelse return bad;
    if (parts == null and n > 0) return bad;
    s.setParts(if (n > 0) parts.?[0..n] else &.{}) catch return no_memory;
    return ok;
}

export fn zs_sel_set_scene(sel: ?*Selection, parts: ?[*]const PartBox, n: usize) c_int {
    const s = sel orelse return bad;
    if (parts == null and n > 0) return bad;
    s.setScene(if (n > 0) parts.?[0..n] else &.{}) catch return no_memory;
    return ok;
}

export fn zs_sel_plate_report(sel: ?*Selection, active: usize, count: usize) void {
    if (sel) |s| s.reportPlate(active, count);
}

export fn zs_sel_answered(sel: ?*Selection, generation: u64) void {
    if (sel) |s| s.answered(generation);
}

export fn zs_sel_sync(sel: ?*Selection, set: ?*Set, scene: c_int) c_int {
    const s = sel orelse return bad;
    const st = set orelse return bad;
    const active = st.activeIndex();
    s.reportPlate(active, st.count());
    s.answered(s.gen);
    const app = st.appOf(active) orelse return bad;
    const table = gpa.alloc(PartBox, app.plate.count()) catch return no_memory;
    defer gpa.free(table);
    for (app.plate.parts.items, table) |*p, *b| b.* = boxOf(p);
    s.setParts(table) catch return no_memory;
    if (scene != 0) s.setScene(table) catch return no_memory;
    return ok;
}

export fn zs_sel_plate(sel: ?*const Selection) usize {
    return if (sel) |s| s.plate() else 0;
}

export fn zs_sel_plate_request(sel: ?*Selection, i: usize) void {
    if (sel) |s| s.requestPlate(i);
}

export fn zs_sel_select(sel: ?*Selection, id: u64, mode: c_int) c_int {
    const s = sel orelse return bad;
    if (mode < 0 or mode > 3) return bad;
    s.select(id, @enumFromInt(mode)) catch return no_memory;
    return ok;
}

export fn zs_sel_clear(sel: ?*Selection) void {
    if (sel) |s| s.clearParts();
}

export fn zs_sel_count(sel: ?*const Selection) usize {
    return if (sel) |s| s.selected.items.len else 0;
}

export fn zs_sel_get(sel: ?*const Selection, k: usize) u64 {
    const s = sel orelse return 0;
    return if (k < s.selected.items.len) s.selected.items[k] else 0;
}

export fn zs_sel_primary(sel: ?*const Selection) u64 {
    return if (sel) |s| s.primary() else 0;
}

export fn zs_sel_has(sel: ?*const Selection, id: u64) c_int {
    const s = sel orelse return 0;
    return @intFromBool(s.has(id));
}

export fn zs_sel_part_index(sel: ?*const Selection, id: u64) isize {
    const s = sel orelse return -1;
    const i = s.indexOf(id) orelse return -1;
    return @intCast(i);
}

export fn zs_sel_part_at(sel: ?*const Selection, index: usize) u64 {
    const s = sel orelse return 0;
    return if (index < s.parts.items.len) s.parts.items[index].id else 0;
}

export fn zs_sel_part_box(sel: ?*const Selection, id: u64, out: ?*PartBox) c_int {
    const s = sel orelse return 0;
    const o = out orelse return 0;
    o.* = s.boxOf(id) orelse return 0;
    return 1;
}

export fn zs_sel_place(sel: ?*Selection, id: u64, x: f64, y: f64, z: f64) c_int {
    const s = sel orelse return bad;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z)) return bad;
    const done = s.place(id, x, y, z) catch return no_memory;
    return if (done) ok else @intFromEnum(Status.out_of_range);
}

export fn zs_sel_pick(sel: ?*const Selection, view: ?*const View, px: f32, py: f32) u64 {
    if (!has_view) return 0;
    const s = sel orelse return 0;
    const v = view orelse return 0;
    var hit: i64 = -1;
    if (v.pick(px, py)) |path| {
        if (path < v.path_part.items.len and v.path_part.items[path] != zs.layer.LayerPlan.no_part) hit = v.path_part.items[path];
    }
    return s.pick(v.ray(px, py), hit, v.bedPoint(px, py));
}

export fn zs_sel_line_set(sel: ?*Selection, key: u64, path: isize, seg: isize) void {
    if (sel) |s| s.setLine(key, path, seg);
}

export fn zs_sel_line_get(sel: ?*const Selection, key: ?*u64, path: ?*isize, seg: ?*isize) void {
    const s = sel orelse return;
    if (key) |k| k.* = s.line_key;
    if (path) |p| p.* = @intCast(s.line_path);
    if (seg) |q| q.* = @intCast(s.line_seg);
}

export fn zs_sel_line_found(sel: ?*Selection, path: isize, segments: isize) void {
    if (sel) |s| s.lineFound(path, segments);
}

export fn zs_sel_hover(sel: ?*const Selection) u64 {
    return if (sel) |s| s.hover else 0;
}

export fn zs_sel_hover_set(sel: ?*Selection, id: u64) void {
    if (sel) |s| s.setHover(id);
}

export fn zs_sel_tool(sel: ?*const Selection) c_int {
    return if (sel) |s| s.tool else 0;
}

export fn zs_sel_tool_set(sel: ?*Selection, tool: c_int) void {
    if (sel) |s| s.setTool(tool);
}

export fn zs_sel_frame_request(sel: ?*Selection, target: isize) void {
    if (sel) |s| s.requestFrame(target);
}

export fn zs_sel_frame_take(sel: ?*Selection, target: ?*isize) c_int {
    const s = sel orelse return 0;
    const t = s.takeFrame() orelse return 0;
    if (target) |o| o.* = @intCast(t);
    return 1;
}

test "selection api: ids stay through move, delete, undo, redo, and a reload" {
    const testing = std.testing;
    var mesh = try zs.mesh.shapes.box(testing.allocator, 20, 20, 10);
    defer mesh.deinit(testing.allocator);
    var stl: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);

    const app = try App.create(testing.allocator, null, null);
    defer app.destroy();
    try app.loadStl("a.stl", stl.written());
    _ = try app.addStl("b.stl", stl.written());
    _ = try app.addStl("c.stl", stl.written());
    const a = zs_app_part_id(app, 0);
    const b = zs_app_part_id(app, 1);
    const d = zs_app_part_id(app, 2);
    try testing.expect(a != 0 and b != 0 and d != 0 and a != b and b != d and a != d);
    _ = app.undo.commit(app, 1);

    // A move keeps the ids.
    app.plate.move(0, 60, 60);
    try app.plateChanged();
    app.undo.note(app.gpa, null, true);
    _ = app.undo.commit(app, 2);
    try testing.expectEqual(a, zs_app_part_id(app, 0));

    // A delete shifts the index of the next part, and its id stays.
    try app.removePart(1);
    app.undo.note(app.gpa, null, true);
    _ = app.undo.commit(app, 3);
    try testing.expectEqual(@as(isize, 1), zs_app_part_index(app, d));
    try testing.expectEqual(@as(isize, -1), zs_app_part_index(app, b));

    // Undo brings the part back with its id, redo takes it out again.
    _ = app.undo.undo(app, 4);
    try testing.expectEqual(@as(isize, 1), zs_app_part_index(app, b));
    try testing.expectEqual(@as(isize, 2), zs_app_part_index(app, d));
    _ = app.undo.redo(app, 5);
    try testing.expectEqual(@as(isize, -1), zs_app_part_index(app, b));
    try testing.expectEqual(@as(isize, 1), zs_app_part_index(app, d));

    // A save and a load keep the ids.
    const bytes = try app.write3mfAlloc(testing.allocator);
    defer testing.allocator.free(bytes);
    const again = try App.create(testing.allocator, null, null);
    defer again.destroy();
    try again.loadStl("p.3mf", bytes);
    try testing.expectEqual(a, zs_app_part_id(again, 0));
    try testing.expectEqual(d, zs_app_part_id(again, 1));

    // A copy is another part.
    const k = try app.duplicatePart(0);
    try testing.expect(zs_app_part_id(app, k) != a);
}

test "selection api: a part keeps its id on another plate" {
    const testing = std.testing;
    var mesh = try zs.mesh.shapes.box(testing.allocator, 20, 20, 10);
    defer mesh.deinit(testing.allocator);
    var stl: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const from = try App.create(testing.allocator, null, null);
    defer from.destroy();
    const to = try App.create(testing.allocator, null, null);
    defer to.destroy();
    try from.loadStl("a.stl", stl.written());
    _ = try from.addStl("b.stl", stl.written());
    const id = zs_app_part_id(from, 1);
    const j = try from.movePartTo(1, to);
    try testing.expectEqual(id, zs_app_part_id(to, j));
}

test "selection api: a sync follows the set, and a removed part leaves the selection" {
    const testing = std.testing;
    var mesh = try zs.mesh.shapes.box(testing.allocator, 20, 20, 10);
    defer mesh.deinit(testing.allocator);
    var stl: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);

    const set = try Set.create(testing.allocator, null, null, false);
    defer set.destroy();
    var sel: Selection = .{ .gpa = gpa };
    defer sel.deinit();
    const app = set.appOf(0).?;
    try app.loadStl("a.stl", stl.written());
    _ = try app.addStl("b.stl", stl.written());
    try testing.expectEqual(ok, zs_sel_sync(&sel, set, 1));
    const a = zs_app_part_id(app, 0);
    const b = zs_app_part_id(app, 1);
    try testing.expectEqual(ok, zs_sel_select(&sel, b, 0));

    // Part a goes: part b has index 0 now, and stays selected.
    try app.removePart(0);
    try testing.expectEqual(ok, zs_sel_sync(&sel, set, 0));
    try testing.expectEqual(b, zs_sel_primary(&sel));
    try testing.expectEqual(@as(isize, 0), zs_sel_part_index(&sel, b));
    try testing.expectEqual(@as(isize, -1), zs_sel_part_index(&sel, a));

    // A new plate: the request ends with the sync, and the selection ends.
    const i = try set.add();
    try set.select(0);
    try testing.expectEqual(ok, zs_sel_sync(&sel, set, 0));
    zs_sel_plate_request(&sel, i);
    try set.select(i);
    try testing.expectEqual(ok, zs_sel_sync(&sel, set, 0));
    try testing.expectEqual(i, zs_sel_plate(&sel));
    try testing.expect(sel.plate_want == null);
    try testing.expectEqual(@as(u64, 0), zs_sel_primary(&sel));
}
