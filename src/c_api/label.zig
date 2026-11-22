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

// ---- the smart guides (label_snap.zig) ----

const snap_mod = zs.label_snap;

fn writeFrame(w: *Writer, f: snap_mod.Frame) Writer.Error!void {
    try w.print("\"origin\":[{d},{d},{d}],\"normal\":[{d},{d},{d}],\"right\":[{d},{d},{d}]", .{ f.origin[0], f.origin[1], f.origin[2], f.normal[0], f.normal[1], f.normal[2], f.right[0], f.right[1], f.right[2] });
}

fn writeFace(w: *Writer, f: snap_mod.Face) Writer.Error!void {
    try w.writeByte('{');
    try writeFrame(w, f.frame);
    try w.print(",\"box\":[{d},{d},{d},{d}],\"center\":[{d},{d}],\"part_center\":[{d},{d}],\"holes\":[", .{ f.box[0], f.box[1], f.box[2], f.box[3], f.center[0], f.center[1], f.part_center[0], f.part_center[1] });
    for (f.holes, 0..) |h, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"kind\":\"{s}\",\"center\":[{d},{d}],\"box\":[{d},{d},{d},{d}],\"radius\":{d},\"size\":[{d},{d}],\"angle\":{d}}}", .{ @tagName(h.kind), h.center[0], h.center[1], h.box[0], h.box[1], h.box[2], h.box[3], h.radius, h.size[0], h.size[1], h.angle });
    }
    try w.writeAll("]}");
}

/// The features of the face of the mesh of a paint session in the plane
/// of a label: frame = origin (3), normal (3), right (3). JSON (see
/// label_snap.zig and include/zslice-app.h), or "null" for no face.
export fn zs_label_face(s: ?*const paint_c.Session, frame: ?*const [9]f64, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const p = s orelse return @intFromEnum(Status.invalid_argument);
    const f = frame orelse return @intFromEnum(Status.invalid_argument);
    const fr = frameFrom(f.*) orelse return @intFromEnum(Status.invalid_value);
    var face = snap_mod.face(gpa, &p.mesh, fr) catch return @intFromEnum(Status.out_of_memory);
    defer if (face) |*x| x.deinit(gpa);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    if (face) |x| writeFace(&aw.writer, x) catch return @intFromEnum(Status.out_of_memory) else aw.writer.writeAll("null") catch return @intFromEnum(Status.out_of_memory);
    return give(aw.written(), buf, cap, out_len);
}

fn frameFrom(f: [9]f64) ?snap_mod.Frame {
    const n = zs.label.normalize(.{ f[3], f[4], f[5] }) orelse return null;
    const r0: [3]f64 = .{ f[6], f[7], f[8] };
    const d = zs.label.dot(r0, n);
    const r = zs.label.normalize(.{ r0[0] - d * n[0], r0[1] - d * n[1], r0[2] - d * n[2] }) orelse return null;
    for (f) |x| if (!std.math.isFinite(x)) return null;
    return .{ .origin = .{ f[0], f[1], f[2] }, .normal = n, .right = r };
}

const SnapError = error{ BadSnap, OutOfMemory };

fn jnum(v: ?std.json.Value) SnapError!f64 {
    const x: f64 = switch (v orelse return error.BadSnap) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => return error.BadSnap,
    };
    if (!std.math.isFinite(x)) return error.BadSnap;
    return x;
}

fn jarr(v: ?std.json.Value, comptime n: usize) SnapError![n]f64 {
    const a = switch (v orelse return error.BadSnap) {
        .array => |x| x.items,
        else => return error.BadSnap,
    };
    if (a.len != n) return error.BadSnap;
    var out: [n]f64 = undefined;
    for (a, &out) |x, *o| o.* = try jnum(x);
    return out;
}

fn jframe(o: std.json.ObjectMap) SnapError!snap_mod.Frame {
    const a = try jarr(o.get("origin"), 3);
    const n = try jarr(o.get("normal"), 3);
    const r = try jarr(o.get("right"), 3);
    return frameFrom(.{ a[0], a[1], a[2], n[0], n[1], n[2], r[0], r[1], r[2] }) orelse error.BadSnap;
}

fn jobj(v: ?std.json.Value) SnapError!std.json.ObjectMap {
    return switch (v orelse return error.BadSnap) {
        .object => |o| o,
        else => error.BadSnap,
    };
}

fn snapJson(a: std.mem.Allocator, json: []const u8, w: *Writer) (SnapError || Writer.Error)!void {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .max_value_len = 1 << 22 }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadSnap,
    };
    const o = try jobj(v);
    var in: snap_mod.Input = .{ .box = try jarr(o.get("box"), 4), .frame = try jframe(try jobj(o.get("frame"))), .tol = try jnum(o.get("tol")) };
    if (o.get("op")) |x| in.op = switch (x) {
        .string => |sv| std.meta.stringToEnum(snap_mod.Op, sv) orelse return error.BadSnap,
        else => return error.BadSnap,
    };
    if (o.get("corner")) |x| {
        const cn = try jarr(x, 2);
        in.corner = .{ if (cn[0] < 0) -1 else 1, if (cn[1] < 0) -1 else 1 };
    }
    if (o.get("aspect")) |x| in.aspect = switch (x) {
        .bool => |b| b,
        else => return error.BadSnap,
    };
    var others: std.ArrayList(snap_mod.Other) = .empty;
    if (o.get("others")) |x| switch (x) {
        .array => |arr| for (arr.items) |it| {
            const io = try jobj(it);
            try others.append(a, .{ .frame = try jframe(io), .box = try jarr(io.get("box"), 4) });
        },
        else => return error.BadSnap,
    };
    in.others = others.items;
    var face: snap_mod.Face = undefined;
    if (o.get("face")) |x| if (x == .object) {
        const fo = x.object;
        face = .{ .frame = try jframe(fo), .box = try jarr(fo.get("box"), 4), .center = try jarr(fo.get("center"), 2), .part_center = try jarr(fo.get("part_center"), 2), .holes = &.{} };
        var holes: std.ArrayList(snap_mod.Hole) = .empty;
        if (fo.get("holes")) |hv| switch (hv) {
            .array => |arr| for (arr.items) |it| {
                const ho = try jobj(it);
                const kind = switch (ho.get("kind") orelse return error.BadSnap) {
                    .string => |sv| std.meta.stringToEnum(snap_mod.HoleKind, sv) orelse return error.BadSnap,
                    else => return error.BadSnap,
                };
                try holes.append(a, .{
                    .kind = kind,
                    .center = try jarr(ho.get("center"), 2),
                    .box = try jarr(ho.get("box"), 4),
                    .radius = if (ho.get("radius")) |r| try jnum(r) else 0,
                    .size = if (ho.get("size")) |r| try jarr(r, 2) else .{ 0, 0 },
                    .angle = if (ho.get("angle")) |r| try jnum(r) else 0,
                });
            },
            else => return error.BadSnap,
        };
        face.holes = holes.items;
        in.face = &face;
    };
    var r = try snap_mod.snap(a, in);
    defer r.deinit(a);
    try w.print("{{\"box\":[{d},{d},{d},{d}],\"d\":[{d},{d}],\"guides\":[", .{ r.box[0], r.box[1], r.box[2], r.box[3], r.d[0], r.d[1] });
    for (r.guides, 0..) |g, k| try w.print("{s}[{d},{d},{d},{d}]", .{ if (k == 0) "" else ",", g[0], g[1], g[2], g[3] });
    try w.writeAll("]}");
}

/// The snap of a label box to the smart guides: JSON in, JSON out (see
/// label_snap.zig and include/zslice-app.h).
export fn zs_label_snap(json: ?[*]const u8, len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const j = json orelse return @intFromEnum(Status.invalid_argument);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    snapJson(arena.allocator(), j[0..len], &aw.writer) catch |e| return @intFromEnum(switch (e) {
        error.OutOfMemory, error.WriteFailed => Status.out_of_memory,
        error.BadSnap => Status.invalid_value,
    });
    return give(aw.written(), buf, cap, out_len);
}

test "C API: the face of a label and a snap" {
    // The top of a box 20 x 20 x 10 as a paint session.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var m = try b.finish();
    defer m.deinit(gpa);
    var verts: std.ArrayList(f32) = .empty;
    defer verts.deinit(gpa);
    for (m.vertices.items) |v| try verts.appendSlice(gpa, &.{ v.x, v.y, v.z });
    var session: ?*paint_c.Session = null;
    try testing.expectEqual(ok, paint_c.zs_paint_new(verts.items.ptr, m.vertices.items.len, @ptrCast(m.faces.items.ptr), m.faces.items.len, &session));
    defer paint_c.zs_paint_free(session);
    const frame = [9]f64{ 5, 5, 10, 0, 0, 1, 1, 0, 0 };
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(ok, zs_label_face(session, &frame, &buf, buf.len, &len));
    const face = buf[0..len];
    try testing.expect(std.mem.indexOf(u8, face, "\"holes\":[]") != null);
    // A box near the center of the face: it moves onto it.
    var in: Writer.Allocating = .init(gpa);
    defer in.deinit();
    try in.writer.print("{{\"op\":\"move\",\"frame\":{{\"origin\":[5,5,10],\"normal\":[0,0,1],\"right\":[1,0,0]}},\"box\":[2.3,-1,8.3,1],\"tol\":0.5,\"face\":{s}}}", .{face});
    var out: [1024]u8 = undefined;
    try testing.expectEqual(ok, zs_label_snap(in.written().ptr, in.written().len, &out, out.len, &len));
    const R = struct { box: [4]f64, d: [2]f64, guides: [][4]f64 };
    const res = try std.json.parseFromSlice(R, gpa, out[0..len], .{});
    defer res.deinit();
    try testing.expectApproxEqAbs(@as(f64, 2), res.value.box[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.3), res.value.d[0], 1e-9);
    try testing.expect(res.value.guides.len >= 1);
    try testing.expectEqual(@intFromEnum(Status.invalid_value), zs_label_snap("{}", 2, &out, out.len, &len));
}

// ---- the snap of a part on the bed (part_snap.zig) ----

/// The snap of a part that moves on the bed (see part_snap.zig and
/// include/zslice-app.h): `box` is its footprint (x0, y0, x1, y1), and
/// `others` has n boxes of the other parts. out gets the move of the snap
/// (dx, dy), and `guides` up to `cap` lines (x0, y0, x1, y1 each).
/// Returns the count of the guides.
export fn zs_part_snap(box: ?*const [4]f64, others: ?[*]const [4]f64, n: usize, bed_x: f64, bed_y: f64, tol: f64, out: ?*[2]f64, guides: ?[*][4]f64, cap: usize) usize {
    const b = box orelse return 0;
    const o: []const [4]f64 = if (others) |p| p[0..n] else &.{};
    const r = zs.part_snap.snap(b.*, o, .{ bed_x, bed_y }, tol);
    if (out) |d| d.* = .{ r.dx, r.dy };
    const k = @min(r.n, cap);
    if (guides) |g| for (0..k) |i| {
        g[i] = r.guides[i];
    };
    return k;
}

test "zs_part_snap: the move and the guides" {
    const others = [_][4]f64{.{ 0, 0, 20, 10 }};
    var d: [2]f64 = undefined;
    var g: [4][4]f64 = undefined;
    const n = zs_part_snap(&.{ 20.6, 40, 30.6, 50 }, &others, 1, 220, 220, 1, &d, &g, 4);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectApproxEqAbs(@as(f64, -0.6), d[0], 1e-9);
}
