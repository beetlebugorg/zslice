//! The C API of the paint of a part (include/zslice-app.h, "paint"): a
//! paint session of one mesh, for the paint tool of a shell. The shell
//! gets the mesh of a part from the app (zs_app_part_mesh) and its paint
//! (zs_app_part_paint_get), makes a session, and then each hover, each
//! smart select, and each stroke of the brush is a call here, on the
//! thread of the view, with no wait for a slice. At the end of a stroke
//! the shell gives the paint back to the app (zs_app_part_paint_set),
//! which slices.
//!
//! The session keeps the regions of the smart select (paint.Features)
//! and a grid of the triangles (paint.Grid), so a hover is a ray through
//! a few cells and a lookup.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const status = c.status;
const ok = c.ok;
const gpa = c.gpa;
const paint = zs.paint;

pub const Session = struct {
    mesh: zs.Mesh,
    features: paint.Features,
    grid: paint.Grid,
    paint: paint.Paint = .{},
    region: std.ArrayList(u32) = .empty,
    leaves: std.ArrayList(f32) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn deinit(s: *Session) void {
        s.mesh.deinit(gpa);
        s.features.deinit(gpa);
        s.grid.deinit(gpa);
        s.paint.deinit(gpa);
        s.region.deinit(gpa);
        s.leaves.deinit(gpa);
        s.text.deinit(gpa);
    }
};

/// A session of a mesh: `nv` vertices (x, y, z) and `nf` triangles (three
/// vertex indices each), in mm.
pub export fn zs_paint_new(verts: ?[*]const f32, nv: usize, faces: ?[*]const u32, nf: usize, out: ?*?*Session) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const v = verts orelse return @intFromEnum(Status.invalid_argument);
    const f = faces orelse return @intFromEnum(Status.invalid_argument);
    if (nf == 0) return @intFromEnum(Status.empty_mesh);
    var mesh: zs.Mesh = .empty;
    mesh.vertices.ensureTotalCapacity(gpa, nv) catch return @intFromEnum(Status.out_of_memory);
    mesh.faces.ensureTotalCapacity(gpa, nf) catch {
        mesh.deinit(gpa);
        return @intFromEnum(Status.out_of_memory);
    };
    for (0..nv) |i| mesh.vertices.appendAssumeCapacity(.{ .x = v[3 * i], .y = v[3 * i + 1], .z = v[3 * i + 2] });
    for (0..nf) |i| {
        const t = [3]u32{ f[3 * i], f[3 * i + 1], f[3 * i + 2] };
        if (t[0] >= nv or t[1] >= nv or t[2] >= nv) {
            mesh.deinit(gpa);
            return @intFromEnum(Status.invalid_mesh);
        }
        mesh.faces.appendAssumeCapacity(t);
    }
    const s = gpa.create(Session) catch {
        mesh.deinit(gpa);
        return @intFromEnum(Status.out_of_memory);
    };
    s.* = .{ .mesh = mesh, .features = .{}, .grid = .{} };
    s.features = paint.Features.init(gpa, &s.mesh) catch {
        s.deinit();
        gpa.destroy(s);
        return @intFromEnum(Status.out_of_memory);
    };
    s.grid = paint.Grid.init(gpa, &s.mesh) catch {
        s.deinit();
        gpa.destroy(s);
        return @intFromEnum(Status.out_of_memory);
    };
    s.paint.ensure(gpa, nf) catch {
        s.deinit();
        gpa.destroy(s);
        return @intFromEnum(Status.out_of_memory);
    };
    o.* = s;
    return ok;
}

pub export fn zs_paint_free(s: ?*Session) void {
    const p = s orelse return;
    p.deinit();
    gpa.destroy(p);
}

/// Sets the paint from its text (the form of zs_app_part_paint_get).
export fn zs_paint_set_text(s: ?*Session, text: ?[*]const u8, len: usize) c_int {
    const p = s orelse return @intFromEnum(Status.invalid_argument);
    const t: []const u8 = if (text) |x| x[0..len] else "";
    p.paint.readLines(gpa, t, p.mesh.faces.items.len) catch return @intFromEnum(Status.out_of_memory);
    p.paint.ensure(gpa, p.mesh.faces.items.len) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

/// The paint as text. The bytes stay valid until the next call.
export fn zs_paint_text(s: ?*Session, out: ?*[*]const u8, out_len: ?*usize) c_int {
    const p = s orelse return @intFromEnum(Status.invalid_argument);
    p.text.clearRetainingCapacity();
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &p.text);
    p.paint.writeLines(p.mesh.faces.items.len, &w.writer) catch return @intFromEnum(Status.out_of_memory);
    p.text = w.toArrayList();
    if (out) |o| o.* = p.text.items.ptr;
    if (out_len) |l| l.* = p.text.items.len;
    return ok;
}

/// The first triangle on a ray (x, y, z, dx, dy, dz; zs_view_ray), and
/// its distance. 1 for a hit, 0 for none.
export fn zs_paint_hit(s: ?*const Session, ray: ?*const [6]f32, tri: ?*u32, t: ?*f32) c_int {
    const p = s orelse return 0;
    const r = ray orelse return 0;
    const h = p.grid.hit(&p.mesh, .{ r[0], r[1], r[2] }, .{ r[3], r[4], r[5] }) orelse return 0;
    if (tri) |o| o.* = h.tri;
    if (t) |o| o.* = h.t;
    return 1;
}

/// The triangles of the smart select of a click on triangle `tri` (see
/// paint.Features): the feature that stands out of the surface (a raised
/// letter), else the flat or smooth face. The list stays valid until the
/// session goes. `id` gets the id of the region.
export fn zs_paint_region(s: ?*Session, tri: u32, out: ?*[*]const u32, n: ?*usize, id: ?*u32) c_int {
    const p = s orelse return @intFromEnum(Status.invalid_argument);
    if (tri >= p.mesh.faces.items.len) return @intFromEnum(Status.out_of_range);
    const list = p.features.regionOf(tri);
    if (out) |o| o.* = list.ptr;
    if (n) |o| o.* = list.len;
    if (id) |o| o.* = p.features.regionId(tri);
    return ok;
}

/// Paints whole triangles with `state` (0: the filament of the part).
/// Returns the count that changed.
export fn zs_paint_fill(s: ?*Session, tris: ?[*]const u32, n: usize, state: u8) c_int {
    const p = s orelse return 0;
    const list = tris orelse return 0;
    var changed: c_int = 0;
    for (list[0..n]) |t| {
        if (t >= p.mesh.faces.items.len) continue;
        if (p.paint.stateOf(t) == state) continue;
        p.paint.setTriangle(gpa, t, state) catch return changed;
        changed += 1;
    }
    return changed;
}

/// Paints the surface in a sphere (center x, y, z, radius r, in mm) with
/// `state`. Triangles on the edge of the sphere split until their pieces
/// are smaller than `fine` mm. Returns the count of triangles that
/// changed.
export fn zs_paint_brush(s: ?*Session, x: f32, y: f32, z: f32, r: f32, state: u8, fine: f32) c_int {
    const p = s orelse return 0;
    const Ctx = struct {
        p: *Session,
        seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
        list: std.ArrayList(u32) = .empty,
        fn add(cx: *@This(), t: u32) void {
            const g = cx.seen.getOrPut(gpa, t) catch return;
            if (g.found_existing) return;
            cx.list.append(gpa, t) catch {};
        }
    };
    var ctx: Ctx = .{ .p = p };
    defer ctx.seen.deinit(gpa);
    defer ctx.list.deinit(gpa);
    p.grid.near(.{ x, y, z }, r, &ctx, Ctx.add);
    var changed: c_int = 0;
    const sphere: paint.Sphere = .{ .c = .{ x, y, z }, .r = r };
    for (ctx.list.items) |t| {
        if (paint.brushTriangle(&p.paint, gpa, &p.mesh, t, sphere, state, @max(fine, 0.05)) catch return changed) changed += 1;
    }
    return changed;
}

/// The state of each triangle (255: split; zs_paint_leaves has its
/// pieces). The bytes stay valid until the next call that changes the
/// paint.
export fn zs_paint_states(s: ?*Session, out: ?*[*]const u8) usize {
    const p = s orelse return 0;
    p.paint.ensure(gpa, p.mesh.faces.items.len) catch return 0;
    if (out) |o| o.* = p.paint.states.items.ptr;
    return p.mesh.faces.items.len;
}

/// The pieces of the split triangles: 10 floats for each (three points,
/// then the state). Valid until the next call.
export fn zs_paint_leaves(s: ?*Session, out: ?*[*]const f32) usize {
    const p = s orelse return 0;
    p.leaves.clearRetainingCapacity();
    const Ctx = struct {
        list: *std.ArrayList(f32),
        fn add(cx: *@This(), a: paint.V3, b: paint.V3, d: paint.V3, st: u8) void {
            const v = [10]f32{ a[0], a[1], a[2], b[0], b[1], b[2], d[0], d[1], d[2], @floatFromInt(st) };
            cx.list.appendSlice(gpa, &v) catch {};
        }
    };
    var ctx: Ctx = .{ .list = &p.leaves };
    for (p.paint.trees.keys()) |t| p.paint.leaves(&p.mesh, t, &ctx, Ctx.add);
    if (out) |o| o.* = p.leaves.items.ptr;
    return p.leaves.items.len / 10;
}
