//! The plate: the parts on the bed, each with its place and its turn.
//!
//! Each part keeps its mesh as the file had it. Its place is the center of
//! its footprint (the box of the turned part, seen from above) in bed
//! coordinates, and its turn is around the vertical axis through the
//! center of its box. `combined` makes one mesh of all parts at their
//! places, each with its bottom at z = 0, for the engine. So the engine
//! slices a plate as it slices one part.
//!
//! A part can have a lift (`Part.z`): its bottom is that far over the bed
//! (it prints on support), or under it (it sinks into the bed, and the
//! slice starts at z 0, so the part below the bed does not print, as the
//! "sinking" objects of PrusaSlicer and OrcaSlicer). The engine slices
//! from z 0 (engine.Job.Options.bed_z).
//!
//! A new part keeps the place of its file if it is on the bed there and
//! does not touch another part; else it goes to a free place, from the
//! center out. `arrange` packs all parts in rows, the largest first, with
//! a gap between them, and puts the rows in the middle of the bed.
//!
//! A part can have its own settings (the metadata of a Cura project 3MF,
//! see part_settings.zig), and modifier volumes: meshes that do not print
//! and that change the settings of the part inside them. A volume belongs
//! to a part: it has the pose, the scale, the turn, and the place of its
//! part, so it moves with it.
//!
//! A part can have paint: a filament for each triangle of its mesh (see
//! paint.zig). A split or a cut of the part drops its paint.
//!
//! A part can have labels (label.zig) in the frame of its file mesh, so
//! they move and turn with it (`Part.placeLabel`). A copy keeps them; a
//! split or a cut drops them.
//!
//! A part can also have the support trees of the user (the support
//! editor, support_skeleton.Edit). They are relative to the center of the
//! footprint, so they move with the part. They also keep the shape of the
//! part (`Part.shape`): a turn or a scale changes the shape, and then the
//! app drops the trees.
//!
//! References (see docs/references/papers-and-algorithms.md): the closest point on a triangle
//! (Ericson, "Real-Time Collision Detection"), for the side of a part
//! nearest to a picked point. The lift of a part, and a part that sinks
//! into the bed: the sinking objects of PrusaSlicer and OrcaSlicer (see
//! docs/references/prusaslicer.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const orient = @import("orient.zig");
const threemf = @import("threemf.zig");
const Meta = threemf.Meta;
const skel = @import("support_skeleton.zig");
const paint_mod = @import("paint.zig");
const label_mod = @import("label.zig");

/// A modifier volume of a part (see the file comment).
pub const Volume = struct {
    name: [:0]u8,
    /// The mesh with the pose and the scale of its part, in the frame of
    /// the mesh of the part.
    mesh: Mesh,
    /// The mesh of the file (see `Part.source`).
    source: ?Mesh = null,
    /// The metadata of the volume: its role and its settings.
    meta: []Meta = &.{},
    /// The content key of `mesh` (see `meshKey`), or 0 if it is not known.
    /// A change of `mesh` sets it to 0.
    mesh_key: u64 = 0,

    fn deinit(v: *Volume, gpa: Allocator) void {
        v.mesh.deinit(gpa);
        if (v.source) |*m| m.deinit(gpa);
        threemf.freeMeta(gpa, v.meta);
        gpa.free(v.name);
    }
};

/// A 3x3 matrix (rows).
pub const M3 = [3][3]f64;
pub const identity: M3 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

fn mulM(a: M3, b: M3) M3 {
    var r: M3 = undefined;
    for (0..3) |i| for (0..3) |j| {
        r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    };
    return r;
}

fn mulV(a: M3, v: [3]f64) [3]f64 {
    return .{ a[0][0] * v[0] + a[0][1] * v[1] + a[0][2] * v[2], a[1][0] * v[0] + a[1][1] * v[1] + a[1][2] * v[2], a[2][0] * v[0] + a[2][1] * v[1] + a[2][2] * v[2] };
}

/// The turn of `deg` degrees about the X (0), Y (1), or Z (2) axis, with
/// the sine and the cosine of a right angle exact.
pub fn axisTurn(axis: u2, deg: f64) M3 {
    const a = std.math.degreesToRadians(deg);
    const c = @round(@cos(a) * 1e12) / 1e12;
    const s = @round(@sin(a) * 1e12) / 1e12;
    return switch (axis) {
        0 => .{ .{ 1, 0, 0 }, .{ 0, c, -s }, .{ 0, s, c } },
        1 => .{ .{ c, 0, s }, .{ 0, 1, 0 }, .{ -s, 0, c } },
        else => .{ .{ c, -s, 0 }, .{ s, c, 0 }, .{ 0, 0, 1 } },
    };
}

/// The orientation of a part on the bed: its turn about Z after its
/// pose.
pub fn orientation(p: *const Part) M3 {
    return mulM(axisTurn(2, p.rot), p.pose);
}

/// The angles x, y, z (degrees) of a turn r = Rz(z) Ry(y) Rx(x). At
/// y = +-90 the turns about X and Z are the same axis: x takes all of it.
pub fn anglesOf(r: M3) [3]f64 {
    const deg = std.math.radiansToDegrees;
    const sy = std.math.clamp(-r[2][0], -1, 1);
    const y = std.math.asin(sy);
    if (@abs(sy) > 1 - 1e-9) {
        // Gimbal lock: z = 0.
        const x = std.math.atan2(-r[1][2], r[1][1]);
        return .{ clean(deg(x)), clean(deg(y)), 0 };
    }
    const x = std.math.atan2(r[2][1], r[2][2]);
    const z = std.math.atan2(r[1][0], r[0][0]);
    return .{ clean(deg(x)), clean(deg(y)), clean(deg(z)) };
}

/// An angle rounded to 1e-6 degrees, with -0 as 0.
fn clean(a: f64) f64 {
    const r = @round(a * 1e6) / 1e6;
    return if (r == 0) 0 else r;
}

/// A label under the map p -> m p + t. `right` and `up` map as vectors;
/// the normal is right x up again. The lengths of the mapped vectors
/// stretch the shape. A mirror keeps the normal out of the part: the
/// shape then mirrors along `up`.
pub fn mapLabel(l: label_mod.Label, m: M3, t: [3]f64) label_mod.Label {
    var out = l;
    const o = mulV(m, l.origin);
    out.origin = .{ o[0] + t[0], o[1] + t[1], o[2] + t[2] };
    const r = mulV(m, l.right);
    const u = mulV(m, l.up());
    const lr = @sqrt(label_mod.dot(r, r));
    const lu = @sqrt(label_mod.dot(u, u));
    if (!(lr > 1e-12) or !(lu > 1e-12)) return out;
    out.right = .{ r[0] / lr, r[1] / lr, r[2] / lr };
    const ru: [3]f64 = .{ u[0] / lu, u[1] / lu, u[2] / lu };
    const n = label_mod.cross(out.right, ru);
    const det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    const flip: f64 = if (det < 0) -1 else 1;
    out.normal = label_mod.normalize(.{ n[0] * flip, n[1] * flip, n[2] * flip }) orelse l.normal;
    out.stretch = .{ l.stretch[0] * lr, l.stretch[1] * lu * flip };
    return out;
}

/// How a part is placed by `Plate.place`.
pub const PlaceMode = enum(u8) {
    /// The least support, the most area on the bed, and a low part.
    smart = 0,
    /// The least support only (the height counts only to break a tie).
    less_support = 1,
    /// Strong along an axis of the part (as in its file): the axis lies in
    /// the layers, and then the least support.
    strength = 2,
};

/// The next free part id. All plates of the process share it, so a part
/// that moves to another plate keeps an id that is free there.
var next_part_id: std.atomic.Value(u32) = .init(1);

/// The largest part id. The counter has 32 bits: wasm32 has no atomic
/// operation on 64 bits.
pub const max_part_id: u64 = std.math.maxInt(u32) - 1;

fn newPartId() u64 {
    return next_part_id.fetchAdd(1, .monotonic);
}

/// Makes sure that the next new id is over `id` (an id from a file).
fn reservePartId(id: u64) void {
    const want: u32 = @intCast(id + 1);
    var at = next_part_id.load(.monotonic);
    while (at < want) at = next_part_id.cmpxchgWeak(at, want, .monotonic, .monotonic) orelse return;
}

pub const Part = struct {
    /// The stable id of the part: it stays through moves, deletes of
    /// other parts, plate changes, undo, redo, and a reload. It is unique
    /// on its plate, and 0 only until a plate takes the part.
    id: u64 = 0,
    /// The name, with a 0 at the end for the C API.
    name: [:0]u8,
    /// The mesh on the plate: `source` with the pose and the scale.
    mesh: Mesh,
    /// The mesh of the file, kept after the first change of the pose or
    /// the scale (so a reset is exact). Null: `mesh` is the file mesh.
    source: ?Mesh = null,
    /// The orientation (rows), and the scale along the axes of the file,
    /// applied first.
    pose: M3 = identity,
    scale: [3]f64 = .{ 1, 1, 1 },
    /// The center of the footprint, in bed coordinates (mm).
    x: f64,
    y: f64,
    /// The turn around the vertical axis, in degrees.
    rot: f64 = 0,
    /// The lift: the height of the lowest point of the part over the bed
    /// (mm). 0: the part is on the bed. Over 0, the part floats: it
    /// prints on support. Under 0, the part sinks into the bed, and the
    /// slice cuts it at z 0 (see `Plate.lift`).
    z: f64 = 0,
    /// The footprint of the turned part, from its center: the half width
    /// and the half depth, and where the center of the box is from the
    /// turn center (so that x, y is the center of the footprint).
    half: [2]f64 = .{ 0, 0 },
    shift: [2]f64 = .{ 0, 0 },
    height: f64 = 0,
    /// The metadata of the part (its own settings), or empty.
    meta: []Meta = &.{},
    /// The modifier volumes of the part.
    volumes: std.ArrayList(Volume) = .empty,
    /// The support trees of the user, or null: the slice plans the trees.
    trees: ?skel.Edit = null,
    /// The paint of the triangles of `mesh` (the same triangles as the
    /// file): a filament for each triangle, or for its pieces (see
    /// paint.zig). Empty: no paint.
    paint: paint_mod.Paint = .{},
    /// True if the faces of `mesh` are reversed from the file (a mirror).
    /// The trees of `paint` follow the order of the vertices of `mesh`.
    faces_flipped: bool = false,
    /// The labels on the surface of the part (see label.zig), in the
    /// frame of the file mesh (`source`, else `mesh`).
    labels: std.ArrayList(label_mod.Label) = .empty,
    /// The content key of `mesh` (see `meshKey`), or 0 if it is not known.
    /// Each change of `mesh` sets it to 0 (`touchMesh`), and the next slice
    /// makes it again. The slice keeps the placed mesh of the part while
    /// this key and the place stay the same (see App.makeSlicePlan).
    mesh_key: u64 = 0,

    fn deinit(p: *Part, gpa: Allocator) void {
        if (p.trees) |*t| t.deinit(gpa);
        p.paint.deinit(gpa);
        p.freeLabels(gpa);
        p.mesh.deinit(gpa);
        if (p.source) |*m| m.deinit(gpa);
        gpa.free(p.name);
        threemf.freeMeta(gpa, p.meta);
        for (p.volumes.items) |*v| v.deinit(gpa);
        p.volumes.deinit(gpa);
    }

    /// Marks the mesh of the part and of its volumes as changed: the next
    /// slice makes their keys again. Call it after each change of `mesh`.
    pub fn touchMesh(p: *Part) void {
        p.mesh_key = 0;
        for (p.volumes.items) |*v| v.mesh_key = 0;
    }

    /// The content key of the mesh of the part, made now if it is not
    /// known.
    pub fn meshKey(p: *Part) u64 {
        if (p.mesh_key == 0) p.mesh_key = p.mesh.contentKey();
        return p.mesh_key;
    }

    /// The key of the placed mesh of the part (`Plate.partMesh`): the
    /// content key of the mesh, and each field that `placed` reads. Volume
    /// k gets k + 1 in `which`, and the content key of its own mesh.
    pub fn placedKey(p: *Part, which: usize) u64 {
        var h = std.hash.Wyhash.init(0x91ace);
        h.update(std.mem.asBytes(&p.meshKey()));
        if (which > 0) {
            const v = &p.volumes.items[which - 1];
            if (v.mesh_key == 0) v.mesh_key = v.mesh.contentKey();
            h.update(std.mem.asBytes(&[2]u64{ which, v.mesh_key }));
        }
        h.update(std.mem.asBytes(&[_]f64{ p.x, p.y, p.z, p.rot, p.shift[0], p.shift[1] }));
        return h.final() | 1;
    }

    pub fn freeLabels(p: *Part, gpa: Allocator) void {
        for (p.labels.items) |*l| l.deinit(gpa);
        p.labels.deinit(gpa);
        p.labels = .empty;
    }

    /// Deep copies of the labels of `src`, with their ids.
    pub fn cloneLabels(gpa: Allocator, src: []const label_mod.Label) Allocator.Error!std.ArrayList(label_mod.Label) {
        var out: std.ArrayList(label_mod.Label) = .empty;
        errdefer {
            for (out.items) |*l| l.deinit(gpa);
            out.deinit(gpa);
        }
        try out.ensureTotalCapacity(gpa, src.len);
        for (src) |*l| out.appendAssumeCapacity(try l.clone(gpa));
        return out;
    }

    /// The index of the label with an id, or null.
    pub fn labelIndex(p: *const Part, id: u32) ?usize {
        for (p.labels.items, 0..) |l, i| if (l.id == id) return i;
        return null;
    }

    /// An id for a new label: one more than the largest id.
    pub fn nextLabelId(p: *const Part) u32 {
        var m: u32 = 0;
        for (p.labels.items) |l| m = @max(m, l.id);
        return m +% 1;
    }

    /// A label of the part in the frame of `mesh` (the pose and the scale
    /// of the part applied). The result shares the items of `l`.
    pub fn meshLabel(p: *const Part, l: label_mod.Label) label_mod.Label {
        if (p.source == null) return l;
        const m: M3 = .{
            .{ p.pose[0][0] * p.scale[0], p.pose[0][1] * p.scale[1], p.pose[0][2] * p.scale[2] },
            .{ p.pose[1][0] * p.scale[0], p.pose[1][1] * p.scale[1], p.pose[1][2] * p.scale[2] },
            .{ p.pose[2][0] * p.scale[0], p.pose[2][1] * p.scale[1], p.pose[2][2] * p.scale[2] },
        };
        return mapLabel(l, m, .{ 0, 0, 0 });
    }

    /// A label of the part in the frame of `Plate.partMesh` (the mesh on
    /// the bed): the pose and the scale, then `transform`. A scale that is
    /// not the same on all axes stretches the label, as it stretches the
    /// part. The result shares the items of `l`.
    pub fn placeLabel(p: *const Part, l: label_mod.Label) label_mod.Label {
        const t = p.transform();
        // The rows of the transform are for row vectors: as a matrix for
        // column vectors, they are the columns.
        const m: M3 = .{ .{ t[0], t[3], t[6] }, .{ t[1], t[4], t[7] }, .{ t[2], t[5], t[8] } };
        return mapLabel(p.meshLabel(l), m, .{ t[9], t[10], t[11] });
    }

    /// Moves a mesh on the bed into the frame of the part (`mesh`): the
    /// inverse of `placed`.
    pub fn fromBed(p: *const Part, m: *Mesh) void {
        const t = p.transform();
        for (m.vertices.items) |*v| {
            const dx = v.x - t[9];
            const dy = v.y - t[10];
            v.* = .{
                .x = @floatCast(dx * t[0] + dy * t[1]),
                .y = @floatCast(dx * t[3] + dy * t[4]),
                .z = @floatCast(v.z - t[11]),
            };
        }
    }

    /// A mesh of the frame of the part (`mesh`) on the bed, at the place
    /// of the part: the transform of `combined`.
    fn placed(p: *const Part, gpa: Allocator, m: *const Mesh, out: *Mesh) Allocator.Error!void {
        const c = p.turnCenter();
        const b = p.mesh.bounds();
        const a = std.math.degreesToRadians(p.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        const base: u32 = @intCast(out.vertices.items.len);
        try out.vertices.ensureUnusedCapacity(gpa, m.vertices.items.len);
        for (m.vertices.items) |v| {
            const dx = v.x - c[0];
            const dy = v.y - c[1];
            const rx = dx * ca - dy * sa - p.shift[0];
            const ry = dx * sa + dy * ca - p.shift[1];
            out.vertices.appendAssumeCapacity(.{
                .x = @floatCast(p.x + rx),
                .y = @floatCast(p.y + ry),
                .z = @floatCast(v.z - b.min[2] + p.z),
            });
        }
        try out.faces.ensureUnusedCapacity(gpa, m.faces.items.len);
        for (m.faces.items) |f| out.faces.appendAssumeCapacity(.{ f[0] + base, f[1] + base, f[2] + base });
    }

    fn turnCenter(p: *const Part) [2]f64 {
        const b = p.mesh.bounds();
        return .{ (b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2 };
    }

    /// Computes the footprint after a change of the turn.
    fn measure(p: *Part) void {
        const c = p.turnCenter();
        const a = std.math.degreesToRadians(p.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        var lo = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        var hi = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
        var zlo: f64 = std.math.inf(f64);
        var zhi: f64 = -std.math.inf(f64);
        for (p.mesh.vertices.items) |v| {
            const dx = v.x - c[0];
            const dy = v.y - c[1];
            const rx = dx * ca - dy * sa;
            const ry = dx * sa + dy * ca;
            lo = .{ @min(lo[0], rx), @min(lo[1], ry) };
            hi = .{ @max(hi[0], rx), @max(hi[1], ry) };
            zlo = @min(zlo, v.z);
            zhi = @max(zhi, v.z);
        }
        p.half = .{ (hi[0] - lo[0]) / 2, (hi[1] - lo[1]) / 2 };
        p.shift = .{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 };
        p.height = zhi - zlo;
    }

    /// The transform of the part from its file to the bed, as a 3MF
    /// transform (a 4x3 matrix for row vectors): the turn around the turn
    /// center, the move to the place, and the bottom to z = `z` (the
    /// lift).
    pub fn transform(p: *const Part) [12]f64 {
        const c = p.turnCenter();
        const b = p.mesh.bounds();
        const a = std.math.degreesToRadians(p.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        // x' = ca (x - cx) - sa (y - cy) - shift x + x0, and the same for y.
        const tx = p.x - p.shift[0] - ca * c[0] + sa * c[1];
        const ty = p.y - p.shift[1] - sa * c[0] - ca * c[1];
        const tz = p.z - b.min[2];
        return .{
            ca,  sa, 0,
            -sa, ca, 0,
            0,   0,  1,
            tx,  ty, tz,
        };
    }

    /// The footprint box: x0, y0, x1, y1.
    pub fn footprint(p: *const Part) [4]f64 {
        return .{ p.x - p.half[0], p.y - p.half[1], p.x + p.half[0], p.y + p.half[1] };
    }

    /// The shape of the part on the bed, for the trees of the user: the
    /// half width and the half depth of the footprint, the height, the
    /// mean place of the vertices (x and y from the center of the
    /// footprint, z from the bed), and the mean of x times y (mm). A move
    /// keeps it; a turn, a scale, or another side on the bed changes it.
    pub fn shape(p: *const Part) [7]f64 {
        const c = p.turnCenter();
        const b = p.mesh.bounds();
        const a = std.math.degreesToRadians(p.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        var m = [4]f64{ 0, 0, 0, 0 };
        const vs = p.mesh.vertices.items;
        for (vs) |v| {
            const dx = v.x - c[0];
            const dy = v.y - c[1];
            const rx = dx * ca - dy * sa - p.shift[0];
            const ry = dx * sa + dy * ca - p.shift[1];
            m[0] += rx;
            m[1] += ry;
            m[2] += v.z - b.min[2];
            m[3] += rx * ry;
        }
        const k: f64 = @floatFromInt(@max(vs.len, 1));
        return .{ p.half[0], p.half[1], p.height, m[0] / k, m[1] / k, m[2] / k, m[3] / k };
    }
};

/// True if two shapes of `Part.shape` are the same, up to the rounding of
/// a file: 0.01 mm (and 0.01 mm times the size for the mean of x y).
pub fn sameShape(a: [7]f64, b: [7]f64) bool {
    const size = @max(1, @max(a[0], a[1]));
    for (a, b, 0..) |x, y, k| {
        const tol: f64 = if (k == 6) 0.01 * size else 0.01;
        if (!(@abs(x - y) <= tol)) return false;
    }
    return true;
}

/// "This side on the bed": faces within this distance (mm) are candidates
/// for the picked side, and faces this far off its plane are not in it.
const side_near = 0.01;
/// A face lower than this over its longest edge (mm) is a sliver.
const side_sliver = 0.05;
/// The cosine of 0.5 degrees: faces of one flat side are within this angle.
const side_cos = 0.99996;

pub const Plate = struct {
    parts: std.ArrayList(Part) = .empty,

    pub fn deinit(self: *Plate, gpa: Allocator) void {
        for (self.parts.items) |*p| p.deinit(gpa);
        self.parts.deinit(gpa);
    }

    pub fn clear(self: *Plate, gpa: Allocator) void {
        self.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: *const Plate) usize {
        return self.parts.items.len;
    }

    /// Adds a part. The plate owns the mesh after the call (also on an
    /// error). `keep_file`: the part keeps the place of its file if it is
    /// on the bed there (with `gap` around it) and touches no other part.
    pub fn add(self: *Plate, gpa: Allocator, name: []const u8, mesh: Mesh, bed: [2]f64, gap: f64, keep_file: bool) Allocator.Error!usize {
        var m = mesh;
        const n = gpa.dupeZ(u8, name) catch |e| {
            m.deinit(gpa);
            return e;
        };
        var part: Part = .{ .name = n, .mesh = m, .x = 0, .y = 0 };
        part.measure();
        const b = m.bounds();
        part.x = (b.min[0] + b.max[0]) / 2;
        part.y = (b.min[1] + b.max[1]) / 2;
        if (!(keep_file and self.fits(&part, bed, gap, null))) {
            const spot = self.freeSpot(&part, bed, gap);
            part.x = spot[0];
            part.y = spot[1];
        }
        self.claimId(&part);
        self.parts.append(gpa, part) catch |e| {
            part.mesh.deinit(gpa);
            gpa.free(part.name);
            return e;
        };
        return self.parts.items.len - 1;
    }

    /// Adds a part whose mesh is in the frame of its file object, with
    /// the place of its build item (a 3MF file, threemf.Place): the part
    /// gets the turn and the place that give the same transform. It keeps
    /// the place if it fits, else it goes to a free place. Returns its
    /// index.
    pub fn addPlaced(self: *Plate, gpa: Allocator, name: []const u8, mesh: Mesh, at: threemf.Place, bed: [2]f64, gap: f64) Allocator.Error!usize {
        var m = mesh;
        const n = gpa.dupeZ(u8, name) catch |e| {
            m.deinit(gpa);
            return e;
        };
        var part: Part = .{ .name = n, .mesh = m, .x = 0, .y = 0, .rot = @mod(at.rot, 360) };
        part.measure();
        // The inverse of `transform` for x and y.
        const c = part.turnCenter();
        const a = std.math.degreesToRadians(part.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        part.x = at.move[0] + part.shift[0] + ca * c[0] - sa * c[1];
        part.y = at.move[1] + part.shift[1] + sa * c[0] + ca * c[1];
        if (!self.fits(&part, bed, gap, null)) {
            const spot = self.freeSpot(&part, bed, gap);
            part.x = spot[0];
            part.y = spot[1];
        }
        self.claimId(&part);
        self.parts.append(gpa, part) catch |e| {
            part.mesh.deinit(gpa);
            gpa.free(part.name);
            return e;
        };
        return self.parts.items.len - 1;
    }

    /// A copy of part i (its mesh, pose, scale, turn, settings, and
    /// modifier volumes) at a free place on the bed. Returns its index.
    pub fn duplicate(self: *Plate, gpa: Allocator, i: usize, bed: [2]f64, gap: f64) Allocator.Error!usize {
        return self.put(gpa, try clonePart(gpa, &self.parts.items[i]), bed, gap);
    }

    /// A deep copy of a part: its mesh, pose, scale, settings, modifier
    /// volumes, support trees, paint, and labels, at the same place. The
    /// caller owns it.
    pub fn clonePart(gpa: Allocator, src: *const Part) Allocator.Error!Part {
        var p: Part = src.*;
        // A copy is another part: the plate that takes it gives it an id.
        p.id = 0;
        p.name = try gpa.dupeZ(u8, src.name);
        errdefer gpa.free(p.name);
        p.mesh = try src.mesh.clone(gpa);
        errdefer p.mesh.deinit(gpa);
        p.source = null;
        if (src.source) |m| p.source = try m.clone(gpa);
        errdefer if (p.source) |*m| m.deinit(gpa);
        p.meta = try threemf.cloneMeta(gpa, src.meta);
        errdefer threemf.freeMeta(gpa, p.meta);
        p.trees = null;
        if (src.trees) |*t| p.trees = try t.clone(gpa);
        errdefer if (p.trees) |*t| t.deinit(gpa);
        p.paint = try src.paint.clone(gpa);
        errdefer p.paint.deinit(gpa);
        p.labels = try Part.cloneLabels(gpa, src.labels.items);
        errdefer p.freeLabels(gpa);
        p.volumes = .empty;
        errdefer {
            for (p.volumes.items) |*v| v.deinit(gpa);
            p.volumes.deinit(gpa);
        }
        for (src.volumes.items) |v| {
            var c: Volume = .{ .name = try gpa.dupeZ(u8, v.name), .mesh = .empty };
            errdefer c.deinit(gpa);
            c.mesh = try v.mesh.clone(gpa);
            if (v.source) |m| c.source = try m.clone(gpa);
            c.meta = try threemf.cloneMeta(gpa, v.meta);
            try p.volumes.append(gpa, c);
        }
        return p;
    }

    /// Frees a part that is on no plate (a copy of clonePart).
    pub fn freePart(gpa: Allocator, p: *Part) void {
        p.deinit(gpa);
    }

    /// A copy of the plate with what a 3MF file of it has (threemf.write):
    /// the names, meshes, metadata, paint, places, and modifier volumes of
    /// the parts. The source meshes and the support trees stay out. A
    /// thread can write the copy while the plate changes.
    pub fn cloneForFile(self: *const Plate, gpa: Allocator) Allocator.Error!Plate {
        var out: Plate = .{};
        errdefer out.deinit(gpa);
        try out.parts.ensureTotalCapacity(gpa, self.parts.items.len);
        for (self.parts.items) |*src| {
            var p: Part = src.*;
            p.source = null;
            p.trees = null;
            p.name = try gpa.dupeZ(u8, src.name);
            p.mesh = .empty;
            p.meta = &.{};
            p.paint = .{};
            p.labels = .empty;
            p.volumes = .empty;
            // The part is in `out` from here, so an error frees it.
            out.parts.appendAssumeCapacity(p);
            const c = &out.parts.items[out.parts.items.len - 1];
            c.mesh = try src.mesh.clone(gpa);
            c.meta = try threemf.cloneMeta(gpa, src.meta);
            c.paint = try src.paint.clone(gpa);
            // The copy has no source mesh: its labels go to the frame of
            // its mesh.
            try c.labels.ensureTotalCapacity(gpa, src.labels.items.len);
            for (src.labels.items) |l| c.labels.appendAssumeCapacity(try src.meshLabel(l).clone(gpa));
            try c.volumes.ensureTotalCapacity(gpa, src.volumes.items.len);
            for (src.volumes.items) |v| {
                c.volumes.appendAssumeCapacity(.{ .name = try gpa.dupeZ(u8, v.name), .mesh = .empty });
                const cv = &c.volumes.items[c.volumes.items.len - 1];
                cv.mesh = try v.mesh.clone(gpa);
                cv.meta = try threemf.cloneMeta(gpa, v.meta);
            }
        }
        return out;
    }

    /// Splits part i into its separate bodies (Mesh.components), each a
    /// part at its place on the bed, with the settings of part i. The
    /// modifier volumes of the part go. Returns the count of the new parts
    /// (they replace part i, from index i on), or 0 if the part has one
    /// body (no change).
    pub fn split(self: *Plate, gpa: Allocator, i: usize, bed: [2]f64, gap: f64) Allocator.Error!usize {
        if (i >= self.parts.items.len) return 0;
        var placed = try self.partMesh(gpa, i);
        defer placed.deinit(gpa);
        const bodies = try placed.components(gpa);
        defer gpa.free(bodies);
        var taken: usize = 0;
        defer for (bodies[taken..]) |*m| m.deinit(gpa);
        if (bodies.len <= 1) return 0;
        const src = &self.parts.items[i];
        const base = try gpa.dupe(u8, src.name);
        defer gpa.free(base);
        const meta = try threemf.cloneMeta(gpa, src.meta);
        defer threemf.freeMeta(gpa, meta);
        self.remove(gpa, i);
        for (bodies, 0..) |m, k| {
            taken = k + 1;
            const name = try std.fmt.allocPrint(gpa, "{s} ({d})", .{ base, k + 1 });
            defer gpa.free(name);
            // The body keeps its place: `add` keeps the place of a mesh in
            // bed coordinates if it fits.
            const j = try self.add(gpa, name, m, bed, gap, true);
            self.setMeta(gpa, j, try threemf.cloneMeta(gpa, meta));
            // From the end to index i + k.
            const part = self.parts.pop().?;
            try self.parts.insert(gpa, i + k, part);
        }
        return bodies.len;
    }

    /// Cuts part i with a level plane at height z above the bed (cut.zig):
    /// the part below and the part above, each closed, with the settings
    /// of part i. `flip` turns the upper part over (180 degrees about X),
    /// so that it prints on its cut face. `pegs`: holes for pegs in both
    /// parts, and the pegs as parts of their own ("<name> (peg)"), so the
    /// parts line up when they are joined. The parts replace part i, from
    /// index i on, the upper part and the pegs go to free places. Returns
    /// the count of new parts (2 and the pegs), or 0 if the plane misses
    /// the part.
    pub fn cut(self: *Plate, gpa: Allocator, i: usize, z: f64, flip: bool, pegs: @import("cut.zig").Pegs, bed: [2]f64, gap: f64) Allocator.Error!usize {
        if (i >= self.parts.items.len) return 0;
        var placed = try self.partMesh(gpa, i);
        defer placed.deinit(gpa);
        var r = try @import("cut.zig").cutZPegs(gpa, placed, z, pegs);
        defer gpa.free(r.pegs);
        var given: u2 = 0;
        defer {
            if (given < 1) r.below.deinit(gpa);
            if (given < 2) r.above.deinit(gpa);
        }
        if (r.below.faces.items.len == 0 or r.above.faces.items.len == 0) return 0;
        if (flip) for (r.above.vertices.items) |*v| {
            v.y = -v.y;
            v.z = -v.z;
        };
        const src = &self.parts.items[i];
        const base = try gpa.dupe(u8, src.name);
        defer gpa.free(base);
        const meta = try threemf.cloneMeta(gpa, src.meta);
        defer threemf.freeMeta(gpa, meta);
        self.remove(gpa, i);
        const names = [2][]const u8{ "bottom", "top" };
        for (0..2) |k| {
            given = @intCast(k + 1);
            const m = if (k == 0) r.below else r.above;
            const name = try std.fmt.allocPrint(gpa, "{s} ({s})", .{ base, names[k] });
            defer gpa.free(name);
            // The bottom keeps its place; the top keeps it if it fits.
            const j = try self.add(gpa, name, m, bed, gap, true);
            self.setMeta(gpa, j, try threemf.cloneMeta(gpa, meta));
            const part = self.parts.pop().?;
            try self.parts.insert(gpa, i + k, part);
        }
        // The pegs: a cylinder each, 1 mm shorter than its two holes.
        for (r.pegs) |pg| {
            const len = pg.below + pg.above - 1;
            const m = mesh_mod.shapes.frustum(gpa, 0, 0, pegs.diameter / 2, pegs.diameter / 2, len, 24) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const name = try std.fmt.allocPrint(gpa, "{s} (peg)", .{base});
            defer gpa.free(name);
            _ = try self.add(gpa, name, m, bed, gap, false);
        }
        // A new part with no free place sits on another part: arrange the
        // plate. If the parts still do not fit, `allFit` says so.
        if (!self.allFit(bed, gap)) _ = try self.arrange(gpa, bed, gap);
        return 2 + r.pegs.len;
    }

    /// True if each part is on the bed and overlaps no other part.
    pub fn allFit(self: *const Plate, bed: [2]f64, gap: f64) bool {
        for (self.parts.items, 0..) |*p, i| if (!self.fits(p, bed, gap, i)) return false;
        return true;
    }

    /// Takes part i off the plate, with its mesh, pose, settings, and
    /// volumes; the caller owns it (put it on a plate with `put`).
    pub fn take(self: *Plate, i: usize) ?Part {
        if (i >= self.parts.items.len) return null;
        return self.parts.orderedRemove(i);
    }

    /// Puts a part on the plate at a free place (the center of the bed if
    /// none is free). The plate owns it after the call, also on an error.
    pub fn put(self: *Plate, gpa: Allocator, part: Part, bed: [2]f64, gap: f64) Allocator.Error!usize {
        var p = part;
        const spot = self.freeSpot(&p, bed, gap);
        p.x = spot[0];
        p.y = spot[1];
        self.claimId(&p);
        self.parts.append(gpa, p) catch |e| {
            p.deinit(gpa);
            return e;
        };
        return self.parts.items.len - 1;
    }

    /// Puts a part on the plate at its place (x, y), with no check for a
    /// free place. The plate owns it after the call, also on an error.
    pub fn putAt(self: *Plate, gpa: Allocator, part: Part) Allocator.Error!usize {
        var p = part;
        self.claimId(&p);
        self.parts.append(gpa, p) catch |e| {
            p.deinit(gpa);
            return e;
        };
        return self.parts.items.len - 1;
    }

    /// Gives a part that comes to this plate an id. It keeps its id if
    /// the id is free here.
    fn claimId(self: *const Plate, p: *Part) void {
        if (p.id == 0 or self.indexOfId(p.id) != null) p.id = newPartId();
    }

    /// The index of the part with this id, or null.
    pub fn indexOfId(self: *const Plate, id: u64) ?usize {
        if (id == 0) return null;
        for (self.parts.items, 0..) |*p, i| if (p.id == id) return i;
        return null;
    }

    /// Gives part i the id of a saved plate. Parts from index `first` on
    /// come from the same file. A new part of that file can hold the id
    /// by chance: it then takes the id of part i, so ids stay unique. A
    /// part before `first` keeps its id, and part i keeps its own.
    pub fn restoreId(self: *Plate, first: usize, i: usize, id: u64) void {
        if (i >= self.parts.items.len or id == 0 or id > max_part_id) return;
        reservePartId(id);
        if (self.indexOfId(id)) |at| {
            if (at == i) return;
            if (at < first) return;
            self.parts.items[at].id = self.parts.items[i].id;
        }
        self.parts.items[i].id = id;
    }

    /// Moves part i to place `to` in the list of the plate: the parts
    /// between them move one place. The list is the print order of
    /// sequential printing (see settings.Project.print_sequence).
    pub fn reorder(self: *Plate, i: usize, to: usize) void {
        const n = self.parts.items.len;
        if (i >= n or to >= n or i == to) return;
        const p = self.parts.orderedRemove(i);
        self.parts.insertAssumeCapacity(to, p);
    }

    pub fn remove(self: *Plate, gpa: Allocator, i: usize) void {
        if (i >= self.parts.items.len) return;
        var p = self.parts.orderedRemove(i);
        p.deinit(gpa);
    }

    /// Sets the metadata of part i (its own settings). The plate owns the
    /// metadata after the call (also on an error).
    pub fn setMeta(self: *Plate, gpa: Allocator, i: usize, meta: []Meta) void {
        if (i >= self.parts.items.len) return threemf.freeMeta(gpa, meta);
        const p = &self.parts.items[i];
        threemf.freeMeta(gpa, p.meta);
        p.meta = meta;
    }

    /// Adds a modifier volume to part i. `mesh` is in the frame of the
    /// file of the part, as the part was loaded. The plate owns the mesh
    /// and the metadata after the call (also on an error).
    pub fn addVolume(self: *Plate, gpa: Allocator, i: usize, name: []const u8, mesh: Mesh, meta: []Meta) Allocator.Error!void {
        var v: Volume = .{ .name = undefined, .mesh = mesh, .meta = meta };
        v.name = gpa.dupeZ(u8, name) catch |e| {
            v.mesh.deinit(gpa);
            threemf.freeMeta(gpa, meta);
            return e;
        };
        errdefer v.deinit(gpa);
        if (i >= self.parts.items.len) return error.OutOfMemory;
        const p = &self.parts.items[i];
        // A part with a pose: the volume gets it too.
        if (p.source != null) {
            v.source = v.mesh;
            v.mesh = .empty;
            try poseMesh(gpa, p, &v.source.?, &v.mesh);
        }
        try p.volumes.append(gpa, v);
    }

    /// Adds a modifier volume to part i from a mesh on the bed (the frame
    /// of `partMesh`): the inverse of the place, the turn, the pose, and
    /// the scale of the part. So the volume moves and turns with the part
    /// after. The plate owns the mesh and the metadata after the call
    /// (also on an error).
    pub fn addVolumeOnBed(self: *Plate, gpa: Allocator, i: usize, name: []const u8, bed: Mesh, meta: []Meta) Allocator.Error!void {
        var m = bed;
        if (i >= self.parts.items.len) {
            m.deinit(gpa);
            threemf.freeMeta(gpa, meta);
            return error.OutOfMemory;
        }
        const p = &self.parts.items[i];
        const c = p.turnCenter();
        const b = p.mesh.bounds();
        const a = std.math.degreesToRadians(p.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        const flip = p.source != null and p.scale[0] * p.scale[1] * p.scale[2] < 0;
        for (m.vertices.items) |*v| {
            const rx = v.x - p.x + p.shift[0];
            const ry = v.y - p.y + p.shift[1];
            var q: [3]f64 = .{ rx * ca + ry * sa + c[0], -rx * sa + ry * ca + c[1], v.z + b.min[2] };
            if (p.source != null) {
                // The pose is a turn: its inverse is its transpose.
                const t = p.pose;
                const u: [3]f64 = .{
                    t[0][0] * q[0] + t[1][0] * q[1] + t[2][0] * q[2],
                    t[0][1] * q[0] + t[1][1] * q[1] + t[2][1] * q[2],
                    t[0][2] * q[0] + t[1][2] * q[1] + t[2][2] * q[2],
                };
                for (0..3) |k| q[k] = if (p.scale[k] != 0) u[k] / p.scale[k] else u[k];
            }
            v.* = .{ .x = @floatCast(q[0]), .y = @floatCast(q[1]), .z = @floatCast(q[2]) };
        }
        // addVolume turns the faces again for a mirror.
        if (flip) for (m.faces.items) |*f| {
            f.* = .{ f[0], f[2], f[1] };
        };
        return self.addVolume(gpa, i, name, m, meta);
    }

    /// Removes modifier volume k of part i.
    pub fn removeVolume(self: *Plate, gpa: Allocator, i: usize, k: usize) void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        if (k >= p.volumes.items.len) return;
        var v = p.volumes.orderedRemove(k);
        v.deinit(gpa);
    }

    /// The mesh of part i on the bed (the transform of `combined`). The
    /// caller owns the result.
    pub fn partMesh(self: *const Plate, gpa: Allocator, i: usize) Allocator.Error!Mesh {
        var out: Mesh = .empty;
        errdefer out.deinit(gpa);
        const p = &self.parts.items[i];
        try p.placed(gpa, &p.mesh, &out);
        return out;
    }

    /// The mesh of volume k of part i on the bed, in the frame of
    /// `combined`. The caller owns the result.
    pub fn volumeMesh(self: *const Plate, gpa: Allocator, i: usize, k: usize) Allocator.Error!Mesh {
        var out: Mesh = .empty;
        errdefer out.deinit(gpa);
        const p = &self.parts.items[i];
        try p.placed(gpa, &p.volumes.items[k].mesh, &out);
        return out;
    }

    pub fn move(self: *Plate, i: usize, x: f64, y: f64) void {
        if (i >= self.parts.items.len) return;
        self.parts.items[i].x = x;
        self.parts.items[i].y = y;
    }

    /// Sets the turn of a part, in degrees, around the center of its
    /// footprint (the part stays at the same place).
    pub fn rotate(self: *Plate, i: usize, deg: f64) void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        p.rot = @mod(deg, 360);
        p.measure();
    }

    /// Makes the mesh of part i again from its source, its pose, and its
    /// scale. The part keeps its place (the center of its footprint).
    fn repose(self: *Plate, gpa: Allocator, i: usize) Allocator.Error!void {
        const p = &self.parts.items[i];
        if (p.source == null) p.source = try cloneMesh(gpa, &p.mesh);
        const src = &p.source.?;
        var m: Mesh = .empty;
        errdefer m.deinit(gpa);
        try m.vertices.ensureTotalCapacity(gpa, src.vertices.items.len);
        for (src.vertices.items) |v| {
            const q = mulV(p.pose, .{ v.x * p.scale[0], v.y * p.scale[1], v.z * p.scale[2] });
            m.vertices.appendAssumeCapacity(.{ .x = @floatCast(q[0]), .y = @floatCast(q[1]), .z = @floatCast(q[2]) });
        }
        // A mirror (a negative scale) turns the faces inside out: flip
        // their order back.
        const flip = p.scale[0] * p.scale[1] * p.scale[2] < 0;
        try m.faces.ensureTotalCapacity(gpa, src.faces.items.len);
        for (src.faces.items) |f| m.faces.appendAssumeCapacity(if (flip) .{ f[0], f[2], f[1] } else f);
        if (flip != p.faces_flipped) {
            try p.paint.reverseFaces(gpa);
            p.faces_flipped = flip;
        }
        p.mesh.deinit(gpa);
        p.mesh = m;
        p.touchMesh();
        p.measure();
        for (p.volumes.items) |*v| {
            if (v.source == null) v.source = try cloneMesh(gpa, &v.mesh);
            var vm: Mesh = .empty;
            errdefer vm.deinit(gpa);
            try poseMesh(gpa, p, &v.source.?, &vm);
            v.mesh.deinit(gpa);
            v.mesh = vm;
        }
    }

    /// After a change of the size of part i: when it no longer fits where
    /// it is (off the bed, or on another part), it goes to a free place,
    /// near the center of the bed first. A part that fits stays.
    pub fn keepOnBed(self: *Plate, i: usize, bed: [2]f64, gap: f64) void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        if (self.fits(p, bed, gap, i)) return;
        const spot = self.freeSpotSkip(p, bed, gap, i);
        p.x = spot[0];
        p.y = spot[1];
    }

    /// Sets the scale of part i along the axes of its file (1 = 100 %).
    pub fn setScale(self: *Plate, gpa: Allocator, i: usize, s: [3]f64) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        for (s) |x| if (!(@abs(x) > 1e-3 and @abs(x) < 1e3)) return;
        self.parts.items[i].scale = s;
        try self.repose(gpa, i);
    }

    /// Mirrors part i along the X (axis 0) or Y (axis 1) axis of the bed.
    /// The part keeps its place. With M the mirror of the bed axis, P the
    /// pose, S the scale, and D the mirror of the first axis of the file:
    /// M P S = (M P D) (D S). M P D is a turn, so it is the new pose, and
    /// D S negates the scale along the first axis of the file. The turn
    /// about z changes its sign: M Rz(a) = Rz(-a) M.
    pub fn mirror(self: *Plate, gpa: Allocator, i: usize, axis: u1) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        for (0..3) |c| p.pose[axis][c] = -p.pose[axis][c];
        for (0..3) |row| p.pose[row][0] = -p.pose[row][0];
        p.scale[0] = -p.scale[0];
        p.rot = @mod(-p.rot, 360);
        try self.repose(gpa, i);
    }

    /// Turns part i by `deg` degrees around the X (0) or Y (1) axis of the
    /// bed: the axes of the rings of the transform tool, also for a part
    /// with a turn about Z. A turn around Z is `rotate`.
    pub fn turn(self: *Plate, gpa: Allocator, i: usize, axis: u2, deg: f64) Allocator.Error!void {
        if (i >= self.parts.items.len or axis > 1) return;
        try self.applyTurn(gpa, i, axisTurn(axis, deg));
    }

    /// The lift of part i (see `Part.z`): over 0 it floats, under 0 it
    /// sinks into the bed. A part sinks at most to `keep` mm over the bed
    /// (some of it must print).
    pub fn lift(self: *Plate, i: usize, z: f64) void {
        if (i >= self.parts.items.len or !std.math.isFinite(z)) return;
        const p = &self.parts.items[i];
        p.z = @max(z, -@max(p.height - min_keep, 0));
        // A lift within a micron of the bed is the bed: the exact slice of
        // a part on the bed stays the same.
        if (@abs(p.z) < 1e-3) p.z = 0;
    }

    /// The least height of a part that sinks into the bed (mm).
    pub const min_keep = 0.5;

    /// The orientation of part i as three angles in degrees: the turns
    /// about X, then Y, then Z of the bed (R = Rz Ry Rx) from the
    /// orientation of its file.
    pub fn angles(self: *const Plate, i: usize) [3]f64 {
        if (i >= self.parts.items.len) return .{ 0, 0, 0 };
        return anglesOf(orientation(&self.parts.items[i]));
    }

    /// Sets the orientation of part i from three angles (see `angles`).
    /// The part keeps its place and its lift.
    pub fn setAngles(self: *Plate, gpa: Allocator, i: usize, a: [3]f64) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        for (a) |x| if (!std.math.isFinite(x)) return;
        const p = &self.parts.items[i];
        // R = Rz(c) Ry(b) Rx(a): the pose is Ry(b) Rx(a), and the turn
        // about Z is c.
        p.pose = mulM(axisTurn(1, a[1]), axisTurn(0, a[0]));
        p.rot = @mod(a[2], 360);
        try self.repose(gpa, i);
    }

    /// Turns part i by the rotation r (rows) in the frame of the bed: the
    /// turn of a body of the physics. The turn about z of the part (`rot`)
    /// stays; r goes into the pose, seen from the mesh.
    pub fn applyTurn(self: *Plate, gpa: Allocator, i: usize, r: M3) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        const a = std.math.degreesToRadians(p.rot);
        const c = @cos(a);
        const s = @sin(a);
        const rz: M3 = .{ .{ c, -s, 0 }, .{ s, c, 0 }, .{ 0, 0, 1 } };
        const rzt: M3 = .{ .{ c, s, 0 }, .{ -s, c, 0 }, .{ 0, 0, 1 } };
        p.pose = mulM(mulM(mulM(rzt, r), rz), p.pose);
        try self.repose(gpa, i);
    }

    /// Moves part i the least way that puts its footprint on the bed, with
    /// `gap` to the edge: a part thrown past the edge stops at the edge.
    pub fn clampOnBed(self: *Plate, i: usize, bed: [2]f64, gap: f64) void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        // The same gap as `fits`, so a clamped part fits, and keepOnBed
        // keeps it there (a part off by a hair went to the center).
        const m = gap + 1e-6;
        for (0..2) |k| {
            const lo = p.half[k] + m;
            const hi = bed[k] - p.half[k] - m;
            const v = if (k == 0) &p.x else &p.y;
            v.* = if (lo > hi) bed[k] / 2 else std.math.clamp(v.*, lo, hi);
        }
    }

    /// Puts the side of part i whose outward normal is `n` (in the
    /// coordinates of its mesh now) on the bed.
    pub fn putDown(self: *Plate, gpa: Allocator, i: usize, n: [3]f64) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        const l = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (!(l > 0)) return;
        const p = &self.parts.items[i];
        p.pose = mulM(orient.downMatrix(.{ n[0] / l, n[1] / l, n[2] / l }), p.pose);
        try self.repose(gpa, i);
    }

    /// The outward normal of the side of part i that the ray from `o` in
    /// direction `d` (bed coordinates) hits first, or null. Only a face
    /// that looks at the ray counts, so the side is the side that shows.
    pub fn sideOnRay(self: *const Plate, i: usize, o: [3]f64, d: [3]f64) ?[3]f64 {
        if (i >= self.parts.items.len) return null;
        const p = &self.parts.items[i];
        const t = p.transform();
        const vs = p.mesh.vertices.items;
        var best: f64 = std.math.inf(f64);
        for (p.mesh.faces.items) |f| {
            var w: [3][3]f64 = undefined;
            for (0..3) |k| {
                const v = vs[f[k]];
                const m = [3]f64{ v.x, v.y, v.z };
                for (0..3) |r| w[k][r] = m[0] * t[r] + m[1] * t[3 + r] + m[2] * t[6 + r] + t[9 + r];
            }
            const e1 = [3]f64{ w[1][0] - w[0][0], w[1][1] - w[0][1], w[1][2] - w[0][2] };
            const e2 = [3]f64{ w[2][0] - w[0][0], w[2][1] - w[0][1], w[2][2] - w[0][2] };
            const h = [3]f64{ d[1] * e2[2] - d[2] * e2[1], d[2] * e2[0] - d[0] * e2[2], d[0] * e2[1] - d[1] * e2[0] };
            // A positive determinant: the face looks at the ray.
            const det = e1[0] * h[0] + e1[1] * h[1] + e1[2] * h[2];
            if (!(det > 1e-12)) continue;
            const g = [3]f64{ o[0] - w[0][0], o[1] - w[0][1], o[2] - w[0][2] };
            const a = (g[0] * h[0] + g[1] * h[1] + g[2] * h[2]) / det;
            if (a < 0 or a > 1) continue;
            const q = [3]f64{ g[1] * e1[2] - g[2] * e1[1], g[2] * e1[0] - g[0] * e1[2], g[0] * e1[1] - g[1] * e1[0] };
            const b = (d[0] * q[0] + d[1] * q[1] + d[2] * q[2]) / det;
            if (b < 0 or a + b > 1) continue;
            const r = (e2[0] * q[0] + e2[1] * q[1] + e2[2] * q[2]) / det;
            if (r > 0 and r < best) best = r;
        }
        if (std.math.isInf(best)) return null;
        return self.sideAt(i, o[0] + best * d[0], o[1] + best * d[1], o[2] + best * d[2]);
    }

    /// The outward normal of the face of part i nearest to the bed point
    /// (x, y, z), in the coordinates of its mesh, or null. For "this side
    /// on the bed" from a picked line.
    pub fn sideAt(self: *const Plate, i: usize, x: f64, y: f64, z: f64) ?[3]f64 {
        if (i >= self.parts.items.len) return null;
        const p = &self.parts.items[i];
        const t = p.transform();
        // From the bed back to the mesh: the turn is a rotation about Z, so
        // its inverse is its transpose.
        const dx = x - t[9];
        const dy = y - t[10];
        const q = [3]f64{ dx * t[0] + dy * t[1], dx * t[3] + dy * t[4], z - t[11] };
        const vs = p.mesh.vertices.items;
        const Tri = struct {
            /// The area vector of a face: its normal, as long as twice its area.
            fn cross(m: *const Mesh, f: [3]u32) [3]f64 {
                const w = m.vertices.items;
                const u = [3]f64{ @as(f64, w[f[1]].x) - w[f[0]].x, @as(f64, w[f[1]].y) - w[f[0]].y, @as(f64, w[f[1]].z) - w[f[0]].z };
                const v = [3]f64{ @as(f64, w[f[2]].x) - w[f[0]].x, @as(f64, w[f[2]].y) - w[f[0]].y, @as(f64, w[f[2]].z) - w[f[0]].z };
                return .{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
            }
            fn len(n: [3]f64) f64 {
                return @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
            }
            /// The height of a face over its longest edge (mm).
            fn height(m: *const Mesh, f: [3]u32) f64 {
                const w = m.vertices.items;
                var longest: f64 = 0;
                for (0..3) |k| {
                    const a = w[f[k]];
                    const b = w[f[(k + 1) % 3]];
                    const e = [3]f64{ @as(f64, b.x) - a.x, @as(f64, b.y) - a.y, @as(f64, b.z) - a.z };
                    longest = @max(longest, len(e));
                }
                return if (longest > 0) len(cross(m, f)) / longest else 0;
            }
            fn dist2(m: *const Mesh, f: [3]u32, at: [3]f64) f64 {
                const w = m.vertices.items;
                const a = [3]f64{ w[f[0]].x, w[f[0]].y, w[f[0]].z };
                const b = [3]f64{ w[f[1]].x, w[f[1]].y, w[f[1]].z };
                const c = [3]f64{ w[f[2]].x, w[f[2]].y, w[f[2]].z };
                return pointTriangle2(at, a, b, c);
            }
        };
        var best_d: f64 = std.math.inf(f64);
        var nearest: ?[3]u32 = null;
        for (p.mesh.faces.items) |f| {
            if (!(Tri.len(Tri.cross(&p.mesh, f)) > 0)) continue;
            const d = Tri.dist2(&p.mesh, f, q);
            if (d < best_d) {
                best_d = d;
                nearest = f;
            }
        }
        const near = nearest orelse return null;
        // The nearest face names the side. Only a sliver has too noisy a
        // normal, so the largest face within 0.01 mm of it names the side.
        var seed_face = near;
        if (Tri.height(&p.mesh, near) < side_sliver) {
            const reach = @sqrt(best_d) + side_near;
            var seed_area: f64 = 0;
            for (p.mesh.faces.items) |f| {
                const l = Tri.len(Tri.cross(&p.mesh, f));
                if (!(l > seed_area) or Tri.dist2(&p.mesh, f, q) > reach * reach) continue;
                seed_face = f;
                seed_area = l;
            }
        }
        const seed_n = Tri.cross(&p.mesh, seed_face);
        const seed_l = Tri.len(seed_n);
        const seed: ?[3]f64 = .{ seed_n[0] / seed_l, seed_n[1] / seed_l, seed_n[2] / seed_l };
        const seed_at = [3]f64{ vs[seed_face[0]].x, vs[seed_face[0]].y, vs[seed_face[0]].z };
        const u = seed orelse return null;
        // The plane of the side: the area-weighted normal of all faces in
        // the plane of the seed face.
        var sum = [3]f64{ 0, 0, 0 };
        for (p.mesh.faces.items) |f| {
            const n = Tri.cross(&p.mesh, f);
            const l = Tri.len(n);
            if (!(l > 0)) continue;
            if ((n[0] * u[0] + n[1] * u[1] + n[2] * u[2]) / l < side_cos) continue;
            const v = vs[f[0]];
            const off = (@as(f64, v.x) - seed_at[0]) * u[0] + (@as(f64, v.y) - seed_at[1]) * u[1] + (@as(f64, v.z) - seed_at[2]) * u[2];
            if (@abs(off) > side_near) continue;
            for (0..3) |k| sum[k] += n[k];
        }
        return sum;
    }

    /// Gives part i, whose mesh already has a pose and a scale (a part
    /// read back from a 3MF file of zslice), that pose and that scale
    /// again, with no change of its mesh: the mesh of the file (`source`)
    /// is the mesh with the pose and the scale taken off, and the labels
    /// go into its frame. The angles, a reset, and a new turn then work as
    /// before the save. A pose that is not a turn, or a scale near 0, is
    /// left out.
    pub fn restorePose(self: *Plate, gpa: Allocator, i: usize, pose: M3, scale: [3]f64) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        for (scale) |x| if (!(@abs(x) > 1e-3 and @abs(x) < 1e3)) return;
        // A turn: the rows are unit vectors at right angles.
        for (0..3) |r| for (0..3) |c| {
            const d = pose[r][0] * pose[c][0] + pose[r][1] * pose[c][1] + pose[r][2] * pose[c][2];
            if (@abs(d - @as(f64, if (r == c) 1 else 0)) > 1e-6) return;
        };
        const p = &self.parts.items[i];
        if (p.source != null) return;
        // The inverse of M = P S: S^-1 P^T.
        var inv: M3 = undefined;
        for (0..3) |r| for (0..3) |c| {
            inv[r][c] = pose[c][r] / scale[r];
        };
        const flip = scale[0] * scale[1] * scale[2] < 0;
        const unpose = struct {
            fn f(g: Allocator, m: *const Mesh, n: M3, fl: bool) Allocator.Error!Mesh {
                var out: Mesh = .empty;
                errdefer out.deinit(g);
                try out.vertices.ensureTotalCapacity(g, m.vertices.items.len);
                for (m.vertices.items) |v| {
                    const q = mulV(n, .{ v.x, v.y, v.z });
                    out.vertices.appendAssumeCapacity(.{ .x = @floatCast(q[0]), .y = @floatCast(q[1]), .z = @floatCast(q[2]) });
                }
                try out.faces.ensureTotalCapacity(g, m.faces.items.len);
                for (m.faces.items) |fc| out.faces.appendAssumeCapacity(if (fl) .{ fc[0], fc[2], fc[1] } else fc);
                return out;
            }
        }.f;
        p.source = try unpose(gpa, &p.mesh, inv, flip);
        for (p.volumes.items) |*v| {
            if (v.source == null) v.source = try unpose(gpa, &v.mesh, inv, flip);
        }
        for (p.labels.items) |*l| {
            const m = mapLabel(l.*, inv, .{ 0, 0, 0 });
            l.origin = m.origin;
            l.normal = m.normal;
            l.right = m.right;
            l.stretch = m.stretch;
        }
        p.pose = pose;
        p.scale = scale;
        p.faces_flipped = flip;
    }

    /// The orientation and the scale of the file again.
    pub fn resetPose(self: *Plate, gpa: Allocator, i: usize) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        p.pose = identity;
        p.scale = .{ 1, 1, 1 };
        if (p.source != null) try self.repose(gpa, i);
    }

    /// Turns part i to the best orientation for `mode`. `axis` (0 X, 1 Y,
    /// 2 Z of the file) is the load axis of the strength mode.
    pub fn place(self: *Plate, gpa: Allocator, i: usize, mode: PlaceMode, axis: u2, support_angle: f64) Allocator.Error!void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        const best = switch (mode) {
            .smart => try orient.best(gpa, &p.mesh, support_angle),
            // Least support first: the height and the bed area only break a
            // tie.
            .less_support => try orient.bestBy(gpa, &p.mesh, support_angle, .overhang),
            .strength => blk: {
                var e: [3]f64 = .{ 0, 0, 0 };
                e[@min(axis, 2)] = 1;
                // The load axis of the file, in the mesh now.
                const ax = mulV(p.pose, e);
                break :blk try orient.bestAlong(gpa, &p.mesh, support_angle, ax);
            },
        };
        try self.putDown(gpa, i, best.dir);
    }

    /// Moves part i to the free spot nearest the middle of the bed, where
    /// it touches no other part (with `gap` around it). The other parts
    /// stay.
    pub fn respot(self: *Plate, i: usize, bed: [2]f64, gap: f64) void {
        if (i >= self.parts.items.len) return;
        const spot = self.freeSpotSkip(&self.parts.items[i], bed, gap, i);
        self.parts.items[i].x = spot[0];
        self.parts.items[i].y = spot[1];
    }

    /// The part whose footprint holds the point, or null. A smaller part
    /// wins, so a part next to a large one can be picked.
    pub fn partAt(self: *const Plate, x: f64, y: f64) ?usize {
        var best: ?usize = null;
        var best_area: f64 = std.math.inf(f64);
        for (self.parts.items, 0..) |*p, i| {
            const f = p.footprint();
            if (x < f[0] or x > f[2] or y < f[1] or y > f[3]) continue;
            const area = (f[2] - f[0]) * (f[3] - f[1]);
            if (area < best_area) {
                best = i;
                best_area = area;
            }
        }
        return best;
    }

    fn overlaps(self: *const Plate, part: *const Part, gap: f64, skip: ?usize) bool {
        const f = part.footprint();
        for (self.parts.items, 0..) |*o, i| {
            if (skip != null and skip.? == i) continue;
            if (o == part) continue;
            const g = o.footprint();
            if (f[0] < g[2] + gap and g[0] < f[2] + gap and f[1] < g[3] + gap and g[1] < f[3] + gap) return true;
        }
        return false;
    }

    /// True if no part is off the bed (with `edge` mm of room at the
    /// edges, for the brim) and no two parts overlap (their boxes). This
    /// is the check of a real fault: arrange keeps the larger gap between
    /// parts, but parts nearer than it print well (their brims join).
    pub fn noFault(self: *const Plate, bed: [2]f64, edge: f64) bool {
        for (self.parts.items, 0..) |*p, i| {
            const f = p.footprint();
            const e = edge - 0.01;
            if (f[0] < e or f[1] < e or f[2] > bed[0] - e or f[3] > bed[1] - e) return false;
            if (self.overlaps(p, -0.01, i)) return false;
        }
        return true;
    }

    fn fits(self: *const Plate, part: *const Part, bed: [2]f64, gap: f64, skip: ?usize) bool {
        const f = part.footprint();
        if (f[0] < gap or f[1] < gap or f[2] > bed[0] - gap or f[3] > bed[1] - gap) return false;
        return !self.overlaps(part, gap, skip);
    }

    /// A free place for a part: the center of the bed, or the nearest free
    /// place to it on a 5 mm grid. If there is none, the center.
    fn freeSpot(self: *const Plate, part: *const Part, bed: [2]f64, gap: f64) [2]f64 {
        return self.freeSpotSkip(part, bed, gap, null);
    }

    /// As freeSpot, with part `skip` (the part itself) out of the check.
    fn freeSpotSkip(self: *const Plate, part: *const Part, bed: [2]f64, gap: f64, skip: ?usize) [2]f64 {
        var probe = part.*;
        const cx = bed[0] / 2;
        const cy = bed[1] / 2;
        const step = 5.0;
        const rings: usize = @intFromFloat(@ceil(@max(bed[0], bed[1]) / step));
        for (0..rings + 1) |r| {
            const rf: f64 = @floatFromInt(r);
            // The points of the square ring at distance r steps.
            var k: i64 = -@as(i64, @intCast(r));
            while (k <= @as(i64, @intCast(r))) : (k += 1) {
                const kf: f64 = @floatFromInt(k);
                const cands = [_][2]f64{
                    .{ cx + kf * step, cy - rf * step }, .{ cx + kf * step, cy + rf * step },
                    .{ cx - rf * step, cy + kf * step }, .{ cx + rf * step, cy + kf * step },
                };
                for (cands) |c| {
                    probe.x = c[0];
                    probe.y = c[1];
                    if (self.fits(&probe, bed, gap, skip)) return c;
                }
            }
        }
        return .{ cx, cy };
    }

    /// Packs all parts in rows across the bed (the largest footprint
    /// first), with `gap` between them, and puts the block in the middle
    /// of the bed. Returns false if the parts do not all fit; they are then
    /// in rows past the bed edge.
    pub fn arrange(self: *Plate, gpa: Allocator, bed: [2]f64, gap: f64) Allocator.Error!bool {
        const n = self.parts.items.len;
        if (n == 0) return true;
        const order = try gpa.alloc(usize, n);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        const parts = self.parts.items;
        std.mem.sort(usize, order, parts, struct {
            fn lt(ps: []Part, a: usize, b: usize) bool {
                const ha = ps[a].half[1];
                const hb = ps[b].half[1];
                if (ha != hb) return ha > hb;
                return ps[a].half[0] > ps[b].half[0];
            }
        }.lt);
        // Shelves: a row is as deep as its first (deepest) part.
        var x: f64 = 0;
        var y: f64 = 0;
        var row_depth: f64 = 0;
        var width: f64 = 0;
        const room = bed[0] - 2 * gap;
        for (order) |i| {
            const p = &parts[i];
            const w = 2 * p.half[0];
            const d = 2 * p.half[1];
            if (x > 0 and x + w > room) {
                y += row_depth + gap;
                x = 0;
                row_depth = 0;
            }
            p.x = x + p.half[0];
            p.y = y + p.half[1];
            x += w + gap;
            row_depth = @max(row_depth, d);
            width = @max(width, x - gap);
        }
        const depth = y + row_depth;
        // The block in the middle of the bed.
        const ox = (bed[0] - width) / 2;
        const oy = (bed[1] - depth) / 2;
        for (parts) |*p| {
            p.x += ox;
            p.y += oy;
        }
        return width <= bed[0] - 2 * gap + 1e-6 and depth <= bed[1] - 2 * gap + 1e-6;
    }

    /// One mesh of all parts at their places, each with its bottom at
    /// its lift (z = 0 for a part on the bed). The caller owns the
    /// result.
    pub fn combined(self: *const Plate, gpa: Allocator) Allocator.Error!Mesh {
        var out: Mesh = .empty;
        errdefer out.deinit(gpa);
        for (self.parts.items) |*p| try p.placed(gpa, &p.mesh, &out);
        return out;
    }
};

const testing = std.testing;

/// The squared distance from p to the triangle a, b, c (Ericson, "Real-Time
/// Collision Detection", 5.1.5: the closest point by the regions of the
/// triangle).
fn pointTriangle2(p: [3]f64, a: [3]f64, b: [3]f64, c: [3]f64) f64 {
    const sub = struct {
        fn f(x: [3]f64, y: [3]f64) [3]f64 {
            return .{ x[0] - y[0], x[1] - y[1], x[2] - y[2] };
        }
    }.f;
    const dotp = struct {
        fn f(x: [3]f64, y: [3]f64) f64 {
            return x[0] * y[0] + x[1] * y[1] + x[2] * y[2];
        }
    }.f;
    const ab = sub(b, a);
    const ac = sub(c, a);
    const ap = sub(p, a);
    const d1 = dotp(ab, ap);
    const d2 = dotp(ac, ap);
    var closest: [3]f64 = a;
    if (d1 <= 0 and d2 <= 0) {
        closest = a;
    } else {
        const bp = sub(p, b);
        const d3 = dotp(ab, bp);
        const d4 = dotp(ac, bp);
        const cp = sub(p, c);
        const d5 = dotp(ab, cp);
        const d6 = dotp(ac, cp);
        const vc = d1 * d4 - d3 * d2;
        const vb = d5 * d2 - d1 * d6;
        const va = d3 * d6 - d5 * d4;
        if (d3 >= 0 and d4 <= d3) {
            closest = b;
        } else if (vc <= 0 and d1 >= 0 and d3 <= 0) {
            const v = d1 / (d1 - d3);
            closest = .{ a[0] + ab[0] * v, a[1] + ab[1] * v, a[2] + ab[2] * v };
        } else if (d6 >= 0 and d5 <= d6) {
            closest = c;
        } else if (vb <= 0 and d2 >= 0 and d6 <= 0) {
            const w = d2 / (d2 - d6);
            closest = .{ a[0] + ac[0] * w, a[1] + ac[1] * w, a[2] + ac[2] * w };
        } else if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) {
            const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
            closest = .{ b[0] + (c[0] - b[0]) * w, b[1] + (c[1] - b[1]) * w, b[2] + (c[2] - b[2]) * w };
        } else {
            const denom = 1 / (va + vb + vc);
            const v = vb * denom;
            const w = vc * denom;
            closest = .{ a[0] + ab[0] * v + ac[0] * w, a[1] + ab[1] * v + ac[1] * w, a[2] + ab[2] * v + ac[2] * w };
        }
    }
    const d = sub(p, closest);
    return dotp(d, d);
}

/// `src` with the pose and the scale of part p, in `out`.
fn poseMesh(gpa: Allocator, p: *const Part, src: *const Mesh, out: *Mesh) Allocator.Error!void {
    try out.vertices.ensureTotalCapacity(gpa, src.vertices.items.len);
    for (src.vertices.items) |v| {
        const q = mulV(p.pose, .{ v.x * p.scale[0], v.y * p.scale[1], v.z * p.scale[2] });
        out.vertices.appendAssumeCapacity(.{ .x = @floatCast(q[0]), .y = @floatCast(q[1]), .z = @floatCast(q[2]) });
    }
    const flip = p.scale[0] * p.scale[1] * p.scale[2] < 0;
    try out.faces.ensureTotalCapacity(gpa, src.faces.items.len);
    for (src.faces.items) |f| out.faces.appendAssumeCapacity(if (flip) .{ f[0], f[2], f[1] } else f);
}

fn cloneMesh(gpa: Allocator, m: *const Mesh) Allocator.Error!Mesh {
    var out: Mesh = .empty;
    errdefer out.deinit(gpa);
    try out.vertices.appendSlice(gpa, m.vertices.items);
    try out.faces.appendSlice(gpa, m.faces.items);
    return out;
}

fn box(gpa: Allocator, x0: f64, y0: f64, x1: f64, y1: f64, h: f64) !Mesh {
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, x0, y0, 0, x1, y1, h);
    return b.finish();
}

test "plate: file place, free place, arrange, and the combined mesh" {
    const gpa = testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    const bed = [2]f64{ 200, 200 };
    // A part on the bed in its file keeps its place.
    _ = try plate.add(gpa, "a", try box(gpa, 10, 10, 30, 20, 5), bed, 3, true);
    try testing.expectApproxEqAbs(@as(f64, 20), plate.parts.items[0].x, 1e-6);
    // The same part again: its file place is taken, so it goes elsewhere,
    // and does not touch the first.
    _ = try plate.add(gpa, "b", try box(gpa, 10, 10, 30, 20, 5), bed, 3, true);
    const fa = plate.parts.items[0].footprint();
    const fb = plate.parts.items[1].footprint();
    try testing.expect(fb[0] >= fa[2] + 3 - 1e-6 or fa[0] >= fb[2] + 3 - 1e-6 or fb[1] >= fa[3] + 3 - 1e-6 or fa[1] >= fb[3] + 3 - 1e-6);
    // A part around the origin goes to a free place on the bed.
    _ = try plate.add(gpa, "c", try box(gpa, -5, -5, 5, 5, 8), bed, 3, true);
    const fc = plate.parts.items[2].footprint();
    try testing.expect(fc[0] >= 3 and fc[1] >= 3);
    // A turn of 90 degrees swaps the width and the depth.
    plate.rotate(0, 90);
    try testing.expectApproxEqAbs(@as(f64, 5), plate.parts.items[0].half[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 10), plate.parts.items[0].half[1], 1e-4);
    // Arrange: all fit, and no two touch.
    try testing.expect(try plate.arrange(gpa, bed, 3));
    for (plate.parts.items, 0..) |*p, i| for (plate.parts.items[i + 1 ..]) |*q| {
        const f = p.footprint();
        const g = q.footprint();
        try testing.expect(!(f[0] < g[2] + 3 - 1e-6 and g[0] < f[2] + 3 - 1e-6 and f[1] < g[3] + 3 - 1e-6 and g[1] < f[3] + 3 - 1e-6));
    };
    // The combined mesh: all parts, bottoms at 0, and its box is the
    // union of the footprints.
    var m = try plate.combined(gpa);
    defer m.deinit(gpa);
    try testing.expectEqual(@as(usize, 36), m.faces.items.len);
    const b = m.bounds();
    try testing.expectApproxEqAbs(@as(f64, 0), b.min[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 8), b.max[2], 1e-4);
    // The picked part: the point at the center of part c.
    try testing.expectEqual(@as(?usize, 2), plate.partAt(plate.parts.items[2].x, plate.parts.items[2].y));
}

test "plate: turn, scale, put down, place, and reset a part" {
    const gpa = std.testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    // A post 5 x 5 x 40 mm.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 5, 5, 40);
    _ = try plate.add(gpa, "post", try b.finish(), .{ 220, 220 }, 3, false);
    const p = &plate.parts.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 40), p.height, 1e-3);
    // A turn of 90 degrees about X lays it down: 5 mm high.
    try plate.turn(gpa, 0, 0, 90);
    try std.testing.expectApproxEqAbs(@as(f64, 5), p.height, 1e-3);
    // 200 % in the axes of the file: 10 mm high, 80 mm long.
    try plate.setScale(gpa, 0, .{ 2, 2, 2 });
    try std.testing.expectApproxEqAbs(@as(f64, 10), p.height, 1e-3);
    // After the turn about X, the long axis is along Y: put its end (the
    // side facing -Y) on the bed, and the post stands again, 80 mm.
    try plate.putDown(gpa, 0, .{ 0, -1, 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 80), p.height, 1e-3);
    // Strong along Z of the file (the long axis): it must lie down.
    try plate.place(gpa, 0, .strength, 2, 50);
    try std.testing.expectApproxEqAbs(@as(f64, 10), p.height, 1e-2);
    // The reset gives the file again: 40 mm.
    try plate.resetPose(gpa, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 40), p.height, 1e-3);
}

test "plate: mirror a part along X and Y of the bed" {
    const gpa = std.testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    _ = try plate.add(gpa, "w", try mesh_mod.shapes.wedge(gpa, 30, 10, 2, 12), .{ 200, 200 }, 3, false);
    // A turn about z and about x first: the mirror is along the bed axes.
    plate.rotate(0, 30);
    try plate.turn(gpa, 0, 0, 90);
    const fp = plate.parts.items[0].footprint();
    var before = try plate.partMesh(gpa, 0);
    defer before.deinit(gpa);
    for ([_]u1{ 0, 1 }) |axis| {
        try plate.mirror(gpa, 0, axis);
        var after = try plate.partMesh(gpa, 0);
        defer after.deinit(gpa);
        // The footprint stays.
        const fa = plate.parts.items[0].footprint();
        for (fp, fa) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-3);
        // Each vertex has its mirror image.
        const c = if (axis == 0) (fp[0] + fp[2]) / 2 else (fp[1] + fp[3]) / 2;
        for (before.vertices.items) |v| {
            var want = [3]f64{ v.x, v.y, v.z };
            want[axis] = 2 * c - want[axis];
            var found = false;
            for (after.vertices.items) |q| {
                if (@abs(q.x - want[0]) < 1e-3 and @abs(q.y - want[1]) < 1e-3 and @abs(q.z - want[2]) < 1e-3) found = true;
            }
            try std.testing.expect(found);
        }
        // The faces still point out: the volume keeps its sign.
        try std.testing.expect(signedVolume(after) * signedVolume(before) > 0);
        // A second mirror gives the part back.
        try plate.mirror(gpa, 0, axis);
        var back = try plate.partMesh(gpa, 0);
        defer back.deinit(gpa);
        for (before.vertices.items, back.vertices.items) |v, q| {
            try std.testing.expectApproxEqAbs(v.x, q.x, 1e-3);
            try std.testing.expectApproxEqAbs(v.y, q.y, 1e-3);
            try std.testing.expectApproxEqAbs(v.z, q.z, 1e-3);
        }
    }
}

fn signedVolume(m: Mesh) f64 {
    var vol: f64 = 0;
    for (m.faces.items) |f| {
        const a = m.vertices.items[f[0]];
        const b = m.vertices.items[f[1]];
        const c = m.vertices.items[f[2]];
        vol += (@as(f64, a.x) * (@as(f64, b.y) * c.z - @as(f64, b.z) * c.y) - @as(f64, a.y) * (@as(f64, b.x) * c.z - @as(f64, b.z) * c.x) + @as(f64, a.z) * (@as(f64, b.x) * c.y - @as(f64, b.y) * c.x)) / 6;
    }
    return vol;
}

test "duplicate a part" {
    const gpa = std.testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    _ = try plate.add(gpa, "a", try box(gpa, 10, 10, 30, 20, 5), .{ 200, 200 }, 3, false);
    const j = try plate.duplicate(gpa, 0, .{ 200, 200 }, 3);
    try std.testing.expectEqual(@as(usize, 1), j);
    try std.testing.expectEqualStrings("a", plate.parts.items[1].name);
    try std.testing.expectEqual(plate.parts.items[0].mesh.faces.items.len, plate.parts.items[1].mesh.faces.items.len);
    // The copy is at another place, with no overlap.
    try std.testing.expect(!plate.overlaps(&plate.parts.items[1], 3, 1));
}

test "plate: split a part into its bodies" {
    const gpa = std.testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 10, 10, 10);
    try mesh_mod.shapes.addBox(&b, 20, 0, 0, 25, 5, 5);
    const m = try b.finish();
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    _ = try plate.add(gpa, "two", m, .{ 200, 200 }, 2, true);
    const before = plate.parts.items[0].footprint();
    try std.testing.expectEqual(@as(usize, 2), try plate.split(gpa, 0, .{ 200, 200 }, 2));
    try std.testing.expectEqual(@as(usize, 2), plate.count());
    try std.testing.expectEqualStrings("two (1)", plate.parts.items[0].name);
    // The bodies keep their places: the large box at the left of the old
    // footprint, the small one at its right.
    const f0 = plate.parts.items[0].footprint();
    const f1 = plate.parts.items[1].footprint();
    try std.testing.expectApproxEqAbs(before[0], f0[0], 1e-6);
    try std.testing.expectApproxEqAbs(before[2], f1[2], 1e-6);
    // One body: no change.
    try std.testing.expectEqual(@as(usize, 0), try plate.split(gpa, 0, .{ 200, 200 }, 2));
}

test "plate: cut a part in two" {
    const gpa = std.testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 30);
    const m = try b.finish();
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    _ = try plate.add(gpa, "box", m, .{ 200, 200 }, 2, false);
    try std.testing.expectEqual(@as(usize, 2), try plate.cut(gpa, 0, 10, true, .{}, .{ 200, 200 }, 2));
    try std.testing.expectEqual(@as(usize, 2), plate.count());
    try std.testing.expectEqualStrings("box (bottom)", plate.parts.items[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 10), plate.parts.items[0].height, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 20), plate.parts.items[1].height, 1e-4);
    // The two parts do not overlap on the bed.
    const f0 = plate.parts.items[0].footprint();
    const f1 = plate.parts.items[1].footprint();
    try std.testing.expect(f1[0] >= f0[2] or f1[2] <= f0[0] or f1[1] >= f0[3] or f1[3] <= f0[1]);
    // A plane over the part: no change.
    try std.testing.expectEqual(@as(usize, 0), try plate.cut(gpa, 0, 50, false, .{}, .{ 200, 200 }, 2));
    // With pegs: 2 parts and 2 pegs.
    try std.testing.expectEqual(@as(usize, 4), try plate.cut(gpa, 1, 10, false, .{ .count = 2 }, .{ 200, 200 }, 2));
    try std.testing.expectEqualStrings("box (top) (peg)", plate.parts.items[plate.count() - 1].name);
}

test "plate: a cut that does not fit side by side arranges the plate" {
    const gpa = std.testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 170, 130, 36);
    const m = try b.finish();
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    _ = try plate.add(gpa, "wide", m, .{ 220, 220 }, 2, false);
    try std.testing.expectEqual(@as(usize, 2), try plate.cut(gpa, 0, 18, true, .{}, .{ 220, 220 }, 2));
    // Two parts of 170 x 130 do not fit on a bed of 220 x 220.
    try std.testing.expect(!plate.allFit(.{ 220, 220 }, 2));
}


test "plate: a part that grows off the bed goes back on it" {
    const gpa = std.testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    var m: Mesh = .empty;
    // A 2 mm cube at the corner of the bed, as a file in inches.
    const v = [_][3]f32{ .{ 4, 4, 0 }, .{ 6, 4, 0 }, .{ 6, 6, 0 }, .{ 4, 6, 0 }, .{ 4, 4, 2 }, .{ 6, 4, 2 }, .{ 6, 6, 2 }, .{ 4, 6, 2 } };
    for (v) |q| try m.vertices.append(gpa, .{ .x = q[0], .y = q[1], .z = q[2] });
    const f = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 1, 2, 6 }, .{ 1, 6, 5 }, .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 3, 0, 4 }, .{ 3, 4, 7 } };
    for (f) |q| try m.faces.append(gpa, q);
    _ = try plate.add(gpa, "cube", m, .{ 220, 220 }, 2, true);
    try std.testing.expectApproxEqAbs(@as(f64, 5), plate.parts.items[0].x, 1e-6);
    try plate.setScale(gpa, 0, .{ 25.4, 25.4, 25.4 });
    try std.testing.expect(!plate.allFit(.{ 220, 220 }, 2));
    plate.keepOnBed(0, .{ 220, 220 }, 2);
    try std.testing.expect(plate.allFit(.{ 220, 220 }, 2));
    // A part that fits stays where it is.
    const x = plate.parts.items[0].x;
    plate.keepOnBed(0, .{ 220, 220 }, 2);
    try std.testing.expectEqual(x, plate.parts.items[0].x);
}

test "plate: parts near each other with a wide brim are no fault" {
    const gpa = std.testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    for ([_]f64{ 50, 75 }) |x| {
        var b: mesh_mod.Builder = .init(gpa);
        try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
        const m = try b.finish();
        const i = try plate.add(gpa, "box", m, .{ 220, 220 }, 2, false);
        plate.parts.items[i].x = x;
        plate.parts.items[i].y = 100;
    }
    // 5 mm apart: arrange wants 16 mm (an 8 mm brim), but they print.
    try std.testing.expect(!plate.allFit(.{ 220, 220 }, 16));
    try std.testing.expect(plate.noFault(.{ 220, 220 }, 8));
    // On top of each other: a fault.
    plate.parts.items[1].x = 60;
    try std.testing.expect(!plate.noFault(.{ 220, 220 }, 8));
    // Past the edge of the bed, with room for the brim: a fault.
    plate.parts.items[1].x = 214;
    try std.testing.expect(!plate.noFault(.{ 220, 220 }, 8));
}

test "plate: a label stays on its face when the part turns and moves" {
    const gpa = std.testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 10, 5);
    _ = try plate.add(gpa, "box", try b.finish(), .{ 200, 200 }, 3, false);
    const items = try gpa.alloc(label_mod.Item, 1);
    items[0] = .{ .shape = .{ .bar = .{ .width = 4, .height = 2 } } };
    try plate.parts.items[0].labels.append(gpa, .{ .id = 1, .name = try gpa.dupe(u8, ""), .origin = .{ 20, 5, 2.5 }, .normal = .{ 1, 0, 0 }, .right = .{ 0, 1, 0 }, .items = items });
    const Check = struct {
        /// The origin is on the face of the box that faces the normal,
        /// and the frame has right angles.
        fn onFace(pl: *const Plate, g: Allocator) !label_mod.Label {
            const p = &pl.parts.items[0];
            const l = p.placeLabel(p.labels.items[0]);
            var m = try pl.partMesh(g, 0);
            defer m.deinit(g);
            var top: f64 = -std.math.inf(f64);
            for (m.vertices.items) |v| top = @max(top, label_mod.dot(.{ v.x, v.y, v.z }, l.normal));
            try std.testing.expectApproxEqAbs(top, label_mod.dot(l.origin, l.normal), 1e-4);
            try std.testing.expectApproxEqAbs(@as(f64, 0), label_mod.dot(l.normal, l.right), 1e-9);
            return l;
        }
    };
    plate.rotate(0, 90);
    plate.move(0, 50, 60);
    const l1 = try Check.onFace(&plate, gpa);
    // +x turns to +y.
    try std.testing.expectApproxEqAbs(@as(f64, 1), l1.normal[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), l1.origin[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), l1.origin[2], 1e-6);
    // A turn of the pose (the part lies on another side), and a scale.
    try plate.turn(gpa, 0, 1, 90);
    _ = try Check.onFace(&plate, gpa);
    try plate.setScale(gpa, 0, .{ 2, 1, 1 });
    const l3 = try Check.onFace(&plate, gpa);
    // The bar stretches with the part along its first axis (y, now up).
    try std.testing.expectApproxEqAbs(@as(f64, 1), l3.stretch[0], 1e-9);
    // A copy keeps the label and its id.
    const k = try plate.duplicate(gpa, 0, .{ 200, 200 }, 3);
    try std.testing.expectEqual(@as(u32, 1), plate.parts.items[k].labels.items[0].id);
}
