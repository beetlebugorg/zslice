//! The C API of the labels of a part (include/zslice-app.h, "the labels
//! of a part"; see label.zig and app/labels.zig). JSON is the exchange
//! form: a shell builds the JSON of a label from its card, and reads the
//! JSON of the labels and of their facts.
//!
//! The frame of a label in the JSON (origin, normal, right) is in the
//! frame of the part on the bed: the frame of zs_app_part_mesh, of the
//! paint session, and of the view. zs_label_place gives it from a ray.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const paint_c = @import("paint.zig");
const Status = c.Status;
const ok = c.ok;
const gpa = c.gpa;
const App = zs.app.App;
const labels = zs.app.labels;
const Writer = std.Io.Writer;

fn noted(app: *App) void {
    app.undo.note(app.gpa, null, true);
}

fn errStatus(e: labels.Error) c_int {
    return @intFromEnum(switch (e) {
        error.OutOfMemory => Status.out_of_memory,
        error.NoPart, error.NoLabel, error.TooMany => Status.out_of_range,
        error.BadLabel => Status.invalid_value,
    });
}

/// Copies `text` into `buf` (at most cap - 1 bytes and a 0), and its
/// length into `out_len` (the rules of zs_app_setting_get).
fn give(text: []const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The JSON of the labels of part i: an array of labels.
export fn zs_app_part_labels_get(a: ?*const App, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    labels.writeJson(app, i, &aw.writer) catch |e| return @intFromEnum(switch (e) {
        error.NoPart => Status.out_of_range,
        error.WriteFailed => Status.out_of_memory,
    });
    return give(aw.written(), buf, cap, out_len);
}

/// Adds a label to part i from its JSON; `id` gets its id.
export fn zs_app_label_add(a: ?*App, i: usize, json: ?[*]const u8, len: usize, id: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const j = json orelse return @intFromEnum(Status.invalid_argument);
    const n = labels.add(app, i, j[0..len]) catch |e| return errStatus(e);
    if (id) |o| o.* = n;
    noted(app);
    return ok;
}

/// Replaces label `id` of part i with its JSON (the id stays).
export fn zs_app_label_update(a: ?*App, i: usize, id: u32, json: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const j = json orelse return @intFromEnum(Status.invalid_argument);
    labels.update(app, i, id, j[0..len]) catch |e| return errStatus(e);
    noted(app);
    return ok;
}

export fn zs_app_label_remove(a: ?*App, i: usize, id: u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    labels.remove(app, i, id) catch |e| return errStatus(e);
    noted(app);
    return ok;
}

/// The frame of a label at a ray on the mesh of a paint session (the mesh
/// of the part on the bed): out = origin (3), normal (3), right (3), and
/// the largest angle (degrees) between the label plane and the face
/// within `radius` mm. 1 for a hit, 0 for none.
export fn zs_label_place(s: ?*const paint_c.Session, ray: ?*const [6]f32, radius: f64, out: ?*[10]f64) c_int {
    const p = s orelse return 0;
    const r = ray orelse return 0;
    const o = out orelse return 0;
    const h = p.grid.hit(&p.mesh, .{ r[0], r[1], r[2] }, .{ r[3], r[4], r[5] }) orelse return 0;
    const t: f64 = h.t;
    const pt: [3]f64 = .{ r[0] + t * r[3], r[1] + t * r[4], r[2] + t * r[5] };
    const pl = zs.label.frameAt(&p.mesh, h.tri, pt, .{ r[3], r[4], r[5] }, p.features.regionOf(h.tri), if (radius > 0) radius else 5);
    o.* = .{ pl.origin[0], pl.origin[1], pl.origin[2], pl.normal[0], pl.normal[1], pl.normal[2], pl.right[0], pl.right[1], pl.right[2], pl.curve };
    return 1;
}

/// The memory of zs_label_outline: valid until the next call on the
/// same thread.
threadlocal var outline_pts: std.ArrayList(f32) = .empty;
threadlocal var outline_ends: std.ArrayList(u32) = .empty;

/// The outline of a label (JSON; the frame is not needed) in its plane,
/// for a live preview: `pts` gets x, y pairs (mm, x along right and y
/// along up, with the stretch), `ends` the end of each path (in points),
/// and `n` the count of paths. Outer paths are counterclockwise, holes
/// clockwise. No slice.
export fn zs_label_outline(json: ?[*]const u8, len: usize, pts: ?*[*]const f32, ends: ?*[*]const u32, n: ?*usize) c_int {
    const j = json orelse return @intFromEnum(Status.invalid_argument);
    var l = zs.label.parse(gpa, j[0..len], .{ .frame = false }) catch |e| return @intFromEnum(switch (e) {
        error.OutOfMemory => Status.out_of_memory,
        error.BadLabel => Status.invalid_value,
    });
    defer l.deinit(gpa);
    var o = zs.label.outline(gpa, &l) catch |e| return @intFromEnum(switch (e) {
        error.OutOfMemory => Status.out_of_memory,
        error.BadFont => Status.invalid_value,
    });
    defer o.deinit(gpa);
    outline_pts.clearRetainingCapacity();
    outline_ends.clearRetainingCapacity();
    outline_pts.ensureTotalCapacity(gpa, 2 * o.points.items.len) catch return @intFromEnum(Status.out_of_memory);
    outline_ends.ensureTotalCapacity(gpa, o.ends.items.len) catch return @intFromEnum(Status.out_of_memory);
    for (o.points.items) |q| {
        outline_pts.appendAssumeCapacity(@floatCast(zs.geom.toMm(q.x)));
        outline_pts.appendAssumeCapacity(@floatCast(zs.geom.toMm(q.y)));
    }
    outline_ends.appendSliceAssumeCapacity(o.ends.items);
    if (pts) |x| x.* = outline_pts.items.ptr;
    if (ends) |x| x.* = outline_ends.items.ptr;
    if (n) |x| x.* = outline_ends.items.len;
    return ok;
}

/// The facts of label `id` of part i, as JSON (see app/labels.zig,
/// `Info`), with "advice": a line of words for the card.
export fn zs_app_label_info(a: ?*const App, i: usize, id: u32, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const in = labels.info(app, i, id) catch |e| return errStatus(e);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var advice: Writer.Allocating = .init(gpa);
    defer advice.deinit();
    labels.writeAdvice(in, &advice.writer) catch return @intFromEnum(Status.out_of_memory);
    labels.writeInfo(in, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    // "...}" -> "...,"advice":"..."}"
    aw.writer.undo(1);
    aw.writer.writeAll(",\"advice\":") catch return @intFromEnum(Status.out_of_memory);
    std.json.Stringify.encodeJsonString(advice.written(), .{}, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    aw.writer.writeByte('}') catch return @intFromEnum(Status.out_of_memory);
    return give(aw.written(), buf, cap, out_len);
}

// ---- tests ----

const testing = std.testing;
const capi_app = @import("app.zig");

test "C API: add, update, outline, info, and remove a label" {
    var app: ?*App = null;
    try testing.expectEqual(ok, capi_app.zs_app_new(null, null, &app));
    defer capi_app.zs_app_free(app);
    // A box 20 x 20 x 10.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var m = try b.finish();
    defer m.deinit(gpa);
    var stl: Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    try testing.expectEqual(ok, capi_app.zs_app_load_stl(app, "box", stl.written().ptr, stl.written().len));
    // The +x face of the part on the bed: from its mesh.
    var verts: [*]const f32 = undefined;
    var nv: usize = 0;
    var faces: [*]const u32 = undefined;
    var nf: usize = 0;
    try testing.expectEqual(ok, capi_app.zs_app_part_mesh(app, 0, &verts, &nv, &faces, &nf));
    var session: ?*paint_c.Session = null;
    try testing.expectEqual(ok, paint_c.zs_paint_new(verts, nv, faces, nf, &session));
    defer paint_c.zs_paint_free(session);
    var xmax: f32 = -1e9;
    var ymid: f32 = 0;
    for (0..nv) |k| xmax = @max(xmax, verts[3 * k]);
    for (0..nv) |k| ymid += verts[3 * k + 1] / @as(f32, @floatFromInt(nv));
    const ray = [6]f32{ xmax + 50, ymid, 5, -1, 0, 0 };
    var frame: [10]f64 = undefined;
    try testing.expectEqual(@as(c_int, 1), zs_label_place(session, &ray, 5, &frame));
    try testing.expectApproxEqAbs(@as(f64, 1), frame[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0), frame[9], 1e-6);
    var json: Writer.Allocating = .init(gpa);
    defer json.deinit();
    try json.writer.print("{{\"origin\":[{d},{d},{d}],\"normal\":[{d},{d},{d}],\"right\":[{d},{d},{d}],\"filament\":2,\"items\":[{{\"kind\":\"text\",\"text\":\"IH\",\"size\":5}}]}}", .{ frame[0], frame[1], frame[2], frame[3], frame[4], frame[5], frame[6], frame[7], frame[8] });
    var id: u32 = 0;
    try testing.expectEqual(ok, zs_app_label_add(app, 0, json.written().ptr, json.written().len, &id));
    try testing.expectEqual(@as(u32, 1), id);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(ok, zs_app_part_labels_get(app, 0, &buf, buf.len, &len));
    const got = buf[0..len];
    try testing.expect(std.mem.indexOf(u8, got, "\"text\":\"IH\"") != null);
    // The outline of the shapes alone.
    var pts: [*]const f32 = undefined;
    var ends: [*]const u32 = undefined;
    var n: usize = 0;
    const bar = "{\"items\":[{\"kind\":\"bar\",\"width\":4,\"height\":2}]}";
    try testing.expectEqual(ok, zs_label_outline(bar, bar.len, &pts, &ends, &n));
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 4), ends[0]);
    const bad = "{\"items\":[{\"kind\":\"bar\"}]}";
    try testing.expectEqual(@intFromEnum(Status.invalid_value), zs_label_outline(bad, bad.len, &pts, &ends, &n));
    // The facts: text 5 mm tall prints clean with a 0.4 nozzle.
    try testing.expectEqual(ok, zs_app_label_info(app, 0, id, &buf, buf.len, &len));
    const info = buf[0..len];
    try testing.expect(std.mem.indexOf(u8, info, "\"kind\":\"side\"") != null);
    try testing.expect(std.mem.indexOf(u8, info, "\"advice\":\"Thinnest stroke") != null);
    // An update keeps the id; a bad JSON changes nothing.
    const upd = try std.mem.replaceOwned(u8, gpa, json.written(), "\"IH\"", "\"VOLUME\"");
    defer gpa.free(upd);
    try testing.expectEqual(ok, zs_app_label_update(app, 0, id, upd.ptr, upd.len));
    try testing.expectEqual(@intFromEnum(Status.invalid_value), zs_app_label_update(app, 0, id, "{}", 2));
    try testing.expectEqual(ok, zs_app_part_labels_get(app, 0, &buf, buf.len, &len));
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "VOLUME") != null);
    try testing.expectEqual(@intFromEnum(Status.out_of_range), zs_app_label_update(app, 0, 99, upd.ptr, upd.len));
    try testing.expectEqual(ok, zs_app_label_remove(app, 0, id));
    try testing.expectEqual(@intFromEnum(Status.out_of_range), zs_app_label_remove(app, 0, id));
    try testing.expectEqual(ok, zs_app_part_labels_get(app, 0, &buf, buf.len, &len));
    try testing.expectEqualStrings("[]", buf[0..len]);
}
