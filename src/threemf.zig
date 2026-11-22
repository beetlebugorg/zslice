//! 3MF files: the parts of a plate, at their places, in a zip of XML.
//!
//! A 3MF file is a zip (see zipfile.zig). [Content_Types].xml and
//! _rels/.rels name the model file, usually 3D/3dmodel.model. Its
//! <resources> have objects: a <mesh> (vertices and triangles), or
//! <components> that point to other objects, with a transform, and with
//! the production extension also in other model files (p:path). The <build>
//! has items: an object and a transform, in the coordinates of the bed.
//! A transform is 12 numbers of a 4x3 matrix for row vectors: x' = x m0 +
//! y m3 + z m6 + m9, and so on. The unit of a model can be other than mm.
//!
//! An object can have metadata: <metadata name="...">text</metadata>. Cura
//! keeps the settings of each object there, for example
//! "cura:infill_mesh" (a modifier volume) or "cura:infill_sparse_density".
//! The reader keeps the metadata of each part. If an item is a group of
//! components and a component has its own metadata, each component with a
//! mesh becomes its own part: a Cura group of a part and its modifier
//! volume is one item with two components.
//!
//! zslice writes one object for each part (its mesh as it was loaded) and
//! one build item with the turn and the place of the part, and its changes
//! for the part and for some layers in Metadata/zslice_overrides.txt (one
//! line each: z_min, z_max, name, value, with tabs between them). The
//! app reads a part with a build item that is a turn about z and a move
//! in the frame of its object (ReadOptions.keep_places). The part then
//! has the same vertices as before the save, to the bit. In the frame of
//! the bed, the f32 vertices round, and the slice can change: for a part
//! with a boss of 0.15 mm under its bottom side, the first layer had the
//! whole side before a reload and only the boss after it.
//!
//! The paint of a triangle (see paint.zig) is its attribute
//! slic3rpe:mmu_segmentation (PrusaSlicer) or paint_color (Bambu Studio).
//! zslice writes both. The reader also takes the filament ("extruder") of
//! each object and part from the config files of Bambu Studio and
//! PrusaSlicer, and the colors of the filaments of the project. A part of
//! one filament gets it as its filament; a group of parts of several
//! filaments that the reader joins gets them as paint. The sizes and the
//! indices of these files are checked: a paint text has a limit of size
//! and depth, and a range of triangles is cut to the mesh.
//!
//! The labels of the parts (label.zig) go in Metadata/zslice_labels.json,
//! each in the frame of the mesh of its object (see `Labels`). Other
//! slicers do not read the entry.
//!
//! Format: 3MF Core Specification 1.3 and the Production Extension, 3MF
//! Consortium, and the Cura project metadata (see docs/references/). The XML reader handles the elements and
//! attributes of these files; it is not a general XML parser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const zipfile = @import("zipfile.zig");
const plate_mod = @import("plate.zig");
const label_mod = @import("label.zig");
const paint_mod = @import("paint.zig");
const Mesh = mesh_mod.Mesh;

pub const Error = error{ NotThreeMf, EmptyMesh, Corrupt, Unsupported } || Allocator.Error;

/// One <metadata> entry of an object: its name (with the namespace, for
/// example "cura:infill_mesh") and its text.
pub const Meta = struct {
    key: []u8,
    value: []u8,
};

pub fn freeMeta(gpa: Allocator, meta: []Meta) void {
    for (meta) |m| {
        gpa.free(m.key);
        gpa.free(m.value);
    }
    gpa.free(meta);
}

pub fn cloneMeta(gpa: Allocator, meta: []const Meta) Allocator.Error![]Meta {
    const out = try gpa.alloc(Meta, meta.len);
    var n: usize = 0;
    errdefer freeMeta(gpa, out[0..n]);
    for (meta) |m| {
        const k = try gpa.dupe(u8, m.key);
        errdefer gpa.free(k);
        out[n] = .{ .key = k, .value = try gpa.dupe(u8, m.value) };
        n += 1;
    }
    return out;
}

/// The place of an object in the build when its transform is a turn
/// about z and a move: the turn (degrees) and the move (mm).
pub const Place = struct {
    rot: f64,
    move: [3]f64,

    /// The transform of the place.
    fn transform(pl: Place) Transform {
        const a = std.math.degreesToRadians(pl.rot);
        const c = @cos(a);
        const s = @sin(a);
        return .{ c, s, 0, -s, c, 0, 0, 0, 1, pl.move[0], pl.move[1], pl.move[2] };
    }
};

/// The place of transform t, or null if t is not a turn about z and a
/// move. The turn comes from the matrix as it is in the file, so the
/// turn of a part that zslice wrote comes back to the last bit or so.
fn placeOf(t: Transform) ?Place {
    if (t[2] != 0 or t[5] != 0 or t[6] != 0 or t[7] != 0 or t[8] != 1) return null;
    if (t[0] != t[4] or t[1] != -t[3]) return null;
    if (@abs(t[0] * t[0] + t[1] * t[1] - 1) > 1e-9) return null;
    for (t[9..12]) |x| if (!(@abs(x) <= mesh_mod.max_coordinate)) return null;
    return .{ .rot = std.math.radiansToDegrees(std.math.atan2(t[1], t[0])), .move = .{ t[9], t[10], t[11] } };
}

/// Moves label l by transform t.
fn moveLabel(l: *label_mod.Label, t: Transform) void {
    const m: plate_mod.M3 = .{ .{ t[0], t[3], t[6] }, .{ t[1], t[4], t[7] }, .{ t[2], t[5], t[8] } };
    const placed = plate_mod.mapLabel(l.*, m, .{ t[9], t[10], t[11] });
    l.origin = placed.origin;
    l.normal = placed.normal;
    l.right = placed.right;
    l.stretch = placed.stretch;
}

pub const LoadedPart = struct {
    name: []u8,
    /// The mesh at its place in the build (the item transform applied),
    /// or, with `place`, the mesh of the object as it is in the file.
    mesh: Mesh,
    /// With ReadOptions.keep_places: the place of the object in the
    /// build, when its transform is a turn about z and a move. The mesh
    /// and the labels are then in the frame of the object, so a part
    /// comes back with the same vertices, to the bit, as zslice wrote
    /// them (see Plate.addPlaced). Null: the mesh is in the build.
    place: ?Place = null,
    /// The metadata of the object, in file order. Empty if it has none.
    meta: []Meta = &.{},
    /// The paint of the triangles of `mesh` (see paint.zig), or empty.
    paint: paint_mod.Paint = .{},
    /// The filament of the part in the file (from 1), or 0: none.
    filament: u8 = 0,
    /// The labels of the part (see label.zig), in the frame of `mesh`.
    labels: []label_mod.Label = &.{},

    pub fn deinit(p: *LoadedPart, gpa: Allocator) void {
        for (p.labels) |*l| l.deinit(gpa);
        gpa.free(p.labels);
        p.labels = &.{};
        gpa.free(p.name);
        p.mesh.deinit(gpa);
        freeMeta(gpa, p.meta);
        p.meta = &.{};
        p.paint.deinit(gpa);
    }

    /// Puts the mesh and the labels in the build (applies `place`).
    pub fn toBuild(p: *LoadedPart) void {
        const pl = p.place orelse return;
        const t = pl.transform();
        for (p.mesh.vertices.items) |*v| {
            const q = apply(t, .{ v.x, v.y, v.z });
            v.* = .{ .x = @floatCast(q[0]), .y = @floatCast(q[1]), .z = @floatCast(q[2]) };
        }
        for (p.labels) |*l| moveLabel(l, t);
        p.place = null;
    }

    /// The box of the mesh in the build.
    pub fn buildBounds(p: *const LoadedPart) mesh_mod.Bounds3 {
        const pl = p.place orelse return p.mesh.bounds();
        const t = pl.transform();
        var b: mesh_mod.Bounds3 = .{ .min = @splat(std.math.inf(f64)), .max = @splat(-std.math.inf(f64)) };
        for (p.mesh.vertices.items) |v| {
            const q = apply(t, .{ v.x, v.y, v.z });
            for (0..3) |k| {
                b.min[k] = @min(b.min[k], q[k]);
                b.max[k] = @max(b.max[k], q[k]);
            }
        }
        return b;
    }

    /// A paint of one filament for all triangles becomes the filament of
    /// the part.
    fn settle(p: *LoadedPart, gpa: Allocator) void {
        if (p.paint.trees.count() > 0 or p.paint.states.items.len < p.mesh.faces.items.len) return;
        const items = p.paint.states.items;
        if (items.len == 0) return;
        for (items) |s| if (s != items[0]) return;
        if (items[0] != 0) p.filament = items[0];
        p.paint.deinit(gpa);
    }
};

pub const Loaded = struct {
    parts: []LoadedPart,
    /// The text of Metadata/zslice_overrides.txt, or empty.
    overrides: []u8,
    /// The colors ("#rrggbb") and the materials of the filaments of the
    /// project of another slicer (Bambu Studio, PrusaSlicer), or empty.
    colors: [][]u8 = &.{},
    materials: [][]u8 = &.{},
    /// The count of the labels that the reader dropped (a bad value, see
    /// label.parse).
    labels_dropped: u32 = 0,

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        for (self.parts) |*p| p.deinit(gpa);
        gpa.free(self.parts);
        gpa.free(self.overrides);
        for (self.colors) |c| gpa.free(c);
        gpa.free(self.colors);
        for (self.materials) |c| gpa.free(c);
        gpa.free(self.materials);
    }
};

const Transform = [12]f64;
const identity: Transform = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };

fn apply(t: Transform, p: [3]f64) [3]f64 {
    return .{
        p[0] * t[0] + p[1] * t[3] + p[2] * t[6] + t[9],
        p[0] * t[1] + p[1] * t[4] + p[2] * t[7] + t[10],
        p[0] * t[2] + p[1] * t[5] + p[2] * t[8] + t[11],
    };
}

/// a, then b.
fn compose(a: Transform, b: Transform) Transform {
    var r: Transform = undefined;
    for (0..3) |col| {
        for (0..3) |row| r[row * 3 + col] = a[row * 3 + 0] * b[0 * 3 + col] + a[row * 3 + 1] * b[1 * 3 + col] + a[row * 3 + 2] * b[2 * 3 + col];
        r[9 + col] = a[9] * b[col] + a[10] * b[3 + col] + a[11] * b[6 + col] + b[9 + col];
    }
    return r;
}

// ---------------------------------------------------------------------------
// A small XML reader: tags and their attributes, with no text.

const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    closing: bool,
    empty: bool,

    fn attr(t: Tag, key: []const u8) ?[]const u8 {
        var s = t.attrs;
        while (std.mem.indexOf(u8, s, key)) |i| {
            const before_ok = i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == '\n' or s[i - 1] == '\r';
            const rest = s[i + key.len ..];
            var j: usize = 0;
            while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t' or rest[j] == '\n' or rest[j] == '\r')) j += 1;
            if (before_ok and j < rest.len and rest[j] == '=') {
                j += 1;
                while (j < rest.len and rest[j] != '"' and rest[j] != '\'') j += 1;
                if (j >= rest.len) return null;
                const q = rest[j];
                const end = std.mem.indexOfScalarPos(u8, rest, j + 1, q) orelse return null;
                return rest[j + 1 .. end];
            }
            s = s[i + key.len ..];
        }
        return null;
    }
};

const Tags = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(it: *Tags) ?Tag {
        while (true) {
            const lt = std.mem.indexOfScalarPos(u8, it.text, it.pos, '<') orelse return null;
            if (std.mem.startsWith(u8, it.text[lt..], "<!--")) {
                const e = std.mem.indexOfPos(u8, it.text, lt, "-->") orelse return null;
                it.pos = e + 3;
                continue;
            }
            const gt = std.mem.indexOfScalarPos(u8, it.text, lt, '>') orelse return null;
            it.pos = gt + 1;
            var body = it.text[lt + 1 .. gt];
            if (body.len == 0 or body[0] == '?' or body[0] == '!') continue;
            const closing = body[0] == '/';
            if (closing) body = body[1..];
            const empty = body.len > 0 and body[body.len - 1] == '/';
            if (empty) body = body[0 .. body.len - 1];
            var n: usize = 0;
            while (n < body.len and body[n] != ' ' and body[n] != '\t' and body[n] != '\n' and body[n] != '\r') n += 1;
            var name = body[0..n];
            // No namespace prefix in the names: "p:path" stays as an
            // attribute, but "m:mesh" is "mesh".
            if (std.mem.lastIndexOfScalar(u8, name, ':')) |c| name = name[c + 1 ..];
            return .{ .name = name, .attrs = body[n..], .closing = closing, .empty = empty };
        }
    }
};

/// A number of the file. A value that is not finite is 0 (the caller
/// checks the size of each point after its transform).
fn parseNum(s: ?[]const u8) f64 {
    const t = std.mem.trim(u8, s orelse return 0, " \t\r\n");
    const v = std.fmt.parseFloat(f64, t) catch return 0;
    return if (std.math.isFinite(v)) v else 0;
}

fn parseTransform(s: ?[]const u8) Transform {
    const text = s orelse return identity;
    var t: Transform = identity;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i >= 12) break;
        t[i] = std.fmt.parseFloat(f64, tok) catch return identity;
        // A transform with a value that is not finite or is huge is no
        // transform.
        if (!(@abs(t[i]) <= 1e6)) return identity;
    }
    return if (i == 12) t else identity;
}

/// Decodes the five XML entities.
fn unescape(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const ents = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" } };
            var hit = false;
            for (ents) |e| if (std.mem.startsWith(u8, s[i..], e[0])) {
                try out.appendSlice(a, e[1]);
                i += e[0].len;
                hit = true;
                break;
            };
            if (hit) continue;
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Read

const Component = struct { path: []const u8, id: []const u8, t: Transform };

const ArenaMeta = struct { key: []const u8, value: []const u8 };

const Object = struct {
    name: []const u8 = "",
    meta: std.ArrayList(ArenaMeta) = .empty,
    verts: std.ArrayList([3]f64) = .empty,
    tris: std.ArrayList([3]u32) = .empty,
    comps: std.ArrayList(Component) = .empty,
    /// The paint text of each painted triangle (see paint.zig).
    paint: std.ArrayList(struct { tri: u32, text: []const u8 }) = .empty,
};

/// The filaments of the objects and the parts of a project of another
/// slicer: Bambu Studio (Metadata/model_settings.config: an "extruder"
/// for each <object> and each <part>) and PrusaSlicer
/// (Metadata/Slic3r_PE_model.config: an "extruder" for each <object> and
/// for each <volume>, a range of triangles).
const Filaments = struct {
    objects: std.StringHashMapUnmanaged(u8) = .empty,
    parts: std.StringHashMapUnmanaged(u8) = .empty,
    volumes: std.ArrayList(struct { object: []const u8, first: u32, last: u32, filament: u8 }) = .empty,
};

const ModelFile = struct {
    scale: f64,
    objects: std.StringHashMapUnmanaged(Object) = .empty,
    items: std.ArrayList(Component) = .empty,
};

fn unitScale(unit: ?[]const u8) f64 {
    const u = unit orelse return 1;
    if (std.mem.eql(u8, u, "micron")) return 0.001;
    if (std.mem.eql(u8, u, "centimeter")) return 10;
    if (std.mem.eql(u8, u, "inch")) return 25.4;
    if (std.mem.eql(u8, u, "foot")) return 304.8;
    if (std.mem.eql(u8, u, "meter")) return 1000;
    return 1;
}

fn parseModel(a: Allocator, text: []const u8, here: []const u8) Error!ModelFile {
    var m: ModelFile = .{ .scale = 1 };
    var it: Tags = .{ .text = text };
    var cur: ?*Object = null;
    var in_build = false;
    while (it.next()) |tag| {
        if (std.mem.eql(u8, tag.name, "model") and !tag.closing) {
            m.scale = unitScale(tag.attr("unit"));
        } else if (std.mem.eql(u8, tag.name, "object")) {
            if (tag.closing) {
                cur = null;
                continue;
            }
            const id = tag.attr("id") orelse continue;
            const gop = try m.objects.getOrPut(a, id);
            gop.value_ptr.* = .{ .name = if (tag.attr("name")) |n| try unescape(a, n) else "" };
            cur = if (tag.empty) null else gop.value_ptr;
        } else if (std.mem.eql(u8, tag.name, "metadata") and !tag.closing and !tag.empty) {
            // Only the metadata of an object: the model has its own.
            const o = cur orelse continue;
            const key = tag.attr("name") orelse continue;
            const end = std.mem.indexOfScalarPos(u8, text, it.pos, '<') orelse continue;
            const value = std.mem.trim(u8, text[it.pos..end], " \t\r\n");
            try o.meta.append(a, .{ .key = try unescape(a, key), .value = try unescape(a, value) });
        } else if (std.mem.eql(u8, tag.name, "vertex")) {
            const o = cur orelse continue;
            try o.verts.append(a, .{ parseNum(tag.attr("x")), parseNum(tag.attr("y")), parseNum(tag.attr("z")) });
        } else if (std.mem.eql(u8, tag.name, "triangle")) {
            const o = cur orelse continue;
            const v1 = std.fmt.parseInt(u32, tag.attr("v1") orelse continue, 10) catch continue;
            const v2 = std.fmt.parseInt(u32, tag.attr("v2") orelse continue, 10) catch continue;
            const v3 = std.fmt.parseInt(u32, tag.attr("v3") orelse continue, 10) catch continue;
            // The paint of the triangle: PrusaSlicer and Bambu Studio.
            if (tag.attr("slic3rpe:mmu_segmentation") orelse tag.attr("paint_color")) |ptext| {
                if (ptext.len > 0) try o.paint.append(a, .{ .tri = @intCast(o.tris.items.len), .text = ptext });
            }
            try o.tris.append(a, .{ v1, v2, v3 });
        } else if (std.mem.eql(u8, tag.name, "component")) {
            const o = cur orelse continue;
            try o.comps.append(a, .{ .path = tag.attr("p:path") orelse here, .id = tag.attr("objectid") orelse continue, .t = parseTransform(tag.attr("transform")) });
        } else if (std.mem.eql(u8, tag.name, "build")) {
            in_build = !tag.closing and !tag.empty;
        } else if (std.mem.eql(u8, tag.name, "item") and in_build) {
            try m.items.append(a, .{ .path = tag.attr("p:path") orelse here, .id = tag.attr("objectid") orelse continue, .t = parseTransform(tag.attr("transform")) });
        }
    }
    return m;
}

/// The limits of a read: the visits of objects through components, and
/// the triangles of all parts. A file of a few kB with components of
/// components could ask for 10^16 visits; past a limit it is corrupt.
const max_visits = 100_000;
const max_triangles = 50_000_000;

const Files = struct {
    a: Allocator,
    entries: []zipfile.Entry,
    fils: ?*const Filaments = null,
    visits: usize = 0,
    parsed: std.StringHashMapUnmanaged(ModelFile) = .empty,
    triangles: usize = 0,

    fn visit(f: *Files) Error!void {
        f.visits += 1;
        if (f.visits > max_visits) return error.Corrupt;
    }

    fn model(f: *Files, path_in: []const u8) Error!*ModelFile {
        const path = std.mem.trimStart(u8, path_in, "/");
        if (f.parsed.getPtr(path)) |m| return m;
        for (f.entries) |e| if (std.ascii.eqlIgnoreCase(e.name, path)) {
            const m = try parseModel(f.a, e.data, path);
            try f.parsed.put(f.a, path, m);
            return f.parsed.getPtr(path).?;
        };
        return error.Corrupt;
    }
};

/// Adds the triangles of object `id` of model file `path`, with the
/// transform `t`, to `out`. `depth` stops a loop of components.
fn addObject(files: *Files, gpa: Allocator, out: *Mesh, path: []const u8, id: []const u8, t: Transform, depth: usize) Error!void {
    return addPainted(files, gpa, out, null, 0, path, id, t, depth);
}

/// `addObject`, with the paint of the triangles in `paint`: the paint of
/// the file, else the filament `fil` of the object or of its part.
fn addPainted(files: *Files, gpa: Allocator, out: *Mesh, paint: ?*paint_mod.Paint, fil: u8, path: []const u8, id: []const u8, t: Transform, depth: usize) Error!void {
    if (depth > 16) return error.Corrupt;
    try files.visit();
    const mf = try files.model(path);
    const o = mf.objects.getPtr(id) orelse return error.Corrupt;
    const s = mf.scale;
    // The budget of the triangles of the whole read, and the room of the
    // u32 indices of the mesh.
    files.triangles += o.tris.items.len;
    if (files.triangles > max_triangles) return error.Corrupt;
    if (out.vertices.items.len + o.verts.items.len > std.math.maxInt(u32)) return error.Corrupt;
    if (paint) |p| if (o.tris.items.len > 0) {
        const face_base = out.faces.items.len;
        if (fil != 0) {
            try p.ensure(gpa, face_base + o.tris.items.len);
            @memset(p.states.items[face_base..][0..o.tris.items.len], fil);
        }
        for (o.paint.items) |pt| p.setText(gpa, face_base + pt.tri, pt.text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // A text that this reader does not know: no paint there.
            error.BadPaint => {},
        };
    };
    if (o.tris.items.len > 0) {
        const base: u32 = @intCast(out.vertices.items.len);
        try out.vertices.ensureUnusedCapacity(gpa, o.verts.items.len);
        for (o.verts.items) |v| {
            const p = apply(t, .{ v[0] * s, v[1] * s, v[2] * s });
            for (p) |x| if (!(@abs(x) <= mesh_mod.max_coordinate)) return error.Corrupt;
            out.vertices.appendAssumeCapacity(.{ .x = @floatCast(p[0]), .y = @floatCast(p[1]), .z = @floatCast(p[2]) });
        }
        try out.faces.ensureUnusedCapacity(gpa, o.tris.items.len);
        for (o.tris.items) |tri| {
            if (tri[0] >= o.verts.items.len or tri[1] >= o.verts.items.len or tri[2] >= o.verts.items.len) return error.Corrupt;
            out.faces.appendAssumeCapacity(.{ tri[0] + base, tri[1] + base, tri[2] + base });
        }
    }
    for (o.comps.items) |c| {
        // The translation of a component is in the units of its file.
        var ct = c.t;
        for (9..12) |k| ct[k] *= s;
        const part_fil = if (files.fils) |f| f.parts.get(c.id) orelse fil else fil;
        try addPainted(files, gpa, out, paint, part_fil, c.path, c.id, compose(ct, t), depth + 1);
    }
}

/// True if a component (at any depth) of object `id` has its own metadata.
fn componentMeta(files: *Files, path: []const u8, id: []const u8, depth: usize) Error!bool {
    if (depth > 16) return error.Corrupt;
    try files.visit();
    const mf = try files.model(path);
    const o = mf.objects.getPtr(id) orelse return error.Corrupt;
    for (o.comps.items) |c| {
        const co = (try files.model(c.path)).objects.getPtr(c.id) orelse return error.Corrupt;
        if (co.meta.items.len > 0) return true;
        if (try componentMeta(files, c.path, c.id, depth + 1)) return true;
    }
    return false;
}

/// The metadata of a part: the metadata of its groups, then its own (a
/// later entry of the same name replaces an earlier one). The caller owns
/// the result.
fn ownMeta(gpa: Allocator, outer: []const ArenaMeta, own: []const ArenaMeta) Allocator.Error![]Meta {
    var out: std.ArrayList(Meta) = .empty;
    errdefer {
        for (out.items) |m| {
            gpa.free(m.key);
            gpa.free(m.value);
        }
        out.deinit(gpa);
    }
    for ([_][]const ArenaMeta{ outer, own }) |list| for (list) |m| {
        const found = for (out.items) |*e| {
            if (std.mem.eql(u8, e.key, m.key)) break e;
        } else null;
        const value = try gpa.dupe(u8, m.value);
        if (found) |e| {
            gpa.free(e.value);
            e.value = value;
            continue;
        }
        errdefer gpa.free(value);
        const key = try gpa.dupe(u8, m.key);
        errdefer gpa.free(key);
        try out.append(gpa, .{ .key = key, .value = value });
    };
    return out.toOwnedSlice(gpa);
}

/// One part for the mesh of object `id` (if it has one) and one for each
/// of its components, at any depth. A part gets the metadata of the groups
/// above it (`outer`) and its own.
fn splitObject(files: *Files, gpa: Allocator, parts: *std.ArrayList(LoadedPart), path: []const u8, id: []const u8, t: Transform, outer: []const ArenaMeta, depth: usize) Error!void {
    if (depth > 16) return error.Corrupt;
    try files.visit();
    const mf = try files.model(path);
    const o = mf.objects.getPtr(id) orelse return error.Corrupt;
    // Copies: a put into the maps below can move the object.
    const name_src = o.name;
    const has_mesh = o.tris.items.len > 0;
    const comps = try files.a.dupe(Component, o.comps.items);
    const s = mf.scale;
    var merged: std.ArrayList(ArenaMeta) = .empty;
    try merged.appendSlice(files.a, outer);
    try merged.appendSlice(files.a, o.meta.items);
    if (has_mesh) {
        var m: Mesh = .empty;
        errdefer m.deinit(gpa);
        // The mesh alone: a copy of the object with no components.
        var bare = o.*;
        bare.comps = .empty;
        const key = try std.fmt.allocPrint(files.a, "{s}#bare", .{id});
        try mf.objects.put(files.a, key, bare);
        var paint: paint_mod.Paint = .{};
        errdefer paint.deinit(gpa);
        const fil = if (files.fils) |f| f.parts.get(id) orelse f.objects.get(id) orelse 0 else 0;
        try addPainted(files, gpa, &m, &paint, fil, path, key, t, depth);
        const name = try gpa.dupe(u8, if (name_src.len > 0) name_src else "part");
        errdefer gpa.free(name);
        const meta = try ownMeta(gpa, &.{}, merged.items);
        try parts.append(gpa, .{ .name = name, .mesh = m, .meta = meta, .paint = paint });
        parts.items[parts.items.len - 1].settle(gpa);
    }
    for (comps) |c| {
        var ct = c.t;
        for (9..12) |k| ct[k] *= s;
        try splitObject(files, gpa, parts, c.path, c.id, compose(ct, t), merged.items, depth + 1);
    }
}

/// Reads the parts of a 3MF file: one for each build item (or for each
/// component of an item, see the file comment), in bed coordinates (mm).
pub const ReadOptions = struct {
    /// Keep the mesh of each object in its own frame when its build item
    /// is a turn about z and a move (see LoadedPart.place).
    keep_places: bool = false,
};

pub fn read(gpa: Allocator, bytes: []const u8) Error!Loaded {
    return readWith(gpa, bytes, .{});
}

pub fn readWith(gpa: Allocator, bytes: []const u8, opts: ReadOptions) Error!Loaded {
    const entries = zipfile.readAll(gpa, bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.NotThreeMf,
    };
    defer zipfile.freeAll(gpa, entries);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var files: Files = .{ .a = a, .entries = entries };

    // The model file: from _rels/.rels, else 3D/3dmodel.model.
    var root: []const u8 = "3D/3dmodel.model";
    for (entries) |e| if (std.ascii.eqlIgnoreCase(e.name, "_rels/.rels")) {
        var it: Tags = .{ .text = e.data };
        while (it.next()) |tag| {
            if (!std.mem.eql(u8, tag.name, "Relationship")) continue;
            const ty = tag.attr("Type") orelse continue;
            if (std.mem.endsWith(u8, ty, "3dmodel")) root = std.mem.trimStart(u8, tag.attr("Target") orelse root, "/");
        }
    };
    var fils: Filaments = .{};
    try readFilaments(a, entries, &fils);
    files.fils = &fils;
    const mf = files.model(root) catch return error.EmptyMesh;

    var labels: Labels = try .init(a, entries);
    var parts: std.ArrayList(LoadedPart) = .empty;
    errdefer {
        for (parts.items) |*p| p.deinit(gpa);
        parts.deinit(gpa);
    }
    for (mf.items.items, 0..) |item, k| {
        var t = item.t;
        for (9..12) |j| t[j] *= mf.scale;
        if (try componentMeta(&files, item.path, item.id, 0)) {
            // A group whose components have their own settings: one part
            // for each component.
            try splitObject(&files, gpa, &parts, item.path, item.id, t, &.{}, 0);
            continue;
        }
        var m: Mesh = .empty;
        errdefer m.deinit(gpa);
        var paint: paint_mod.Paint = .{};
        errdefer paint.deinit(gpa);
        const fil = fils.objects.get(item.id) orelse 0;
        // The mesh in the frame of the object, and its place.
        const place = if (opts.keep_places) placeOf(t) else null;
        if (place != null) t = identity;
        try addPainted(&files, gpa, &m, &paint, fil, item.path, item.id, t, 0);
        if (m.faces.items.len == 0) {
            m.deinit(gpa);
            paint.deinit(gpa);
            continue;
        }
        // The volumes of PrusaSlicer: ranges of triangles of the object.
        for (fils.volumes.items) |v| {
            if (!std.mem.eql(u8, v.object, item.id) or v.filament == 0) continue;
            const last = @min(@as(usize, v.last) + 1, m.faces.items.len);
            if (v.first >= last) continue;
            try paint.ensure(gpa, last);
            for (v.first..last) |f| if (paint.states.items[f] == 0 or paint.states.items[f] == fil) {
                paint.states.items[f] = v.filament;
            };
        }
        const obj = (try files.model(item.path)).objects.getPtr(item.id);
        const name = if (obj != null and obj.?.name.len > 0)
            try gpa.dupe(u8, obj.?.name)
        else
            try std.fmt.allocPrint(gpa, "part {d}", .{k + 1});
        errdefer gpa.free(name);
        const meta = try ownMeta(gpa, &.{}, if (obj) |o| o.meta.items else &.{});
        try parts.append(gpa, .{ .name = name, .mesh = m, .meta = meta, .paint = paint, .place = place });
        const lp = &parts.items[parts.items.len - 1];
        lp.settle(gpa);
        if (std.fmt.parseInt(u32, item.id, 10)) |oid| {
            lp.labels = try labels.take(gpa, oid, t);
        } else |_| {}
    }
    if (parts.items.len == 0) return error.EmptyMesh;
    var overrides: []u8 = try gpa.dupe(u8, "");
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/zslice_overrides.txt")) {
        gpa.free(overrides);
        overrides = try gpa.dupe(u8, e.data);
    };
    var loaded: Loaded = .{ .parts = try parts.toOwnedSlice(gpa), .overrides = overrides, .labels_dropped = labels.dropped };
    errdefer loaded.deinit(gpa);
    try readColors(gpa, entries, &loaded);
    return loaded;
}

/// The name of the entry of the labels (see label.zig).
pub const labels_entry = "Metadata/zslice_labels.json";
/// The largest labels entry that the reader reads.
const max_labels_bytes = 8 << 20;
/// The most labels of one object.
pub const max_labels = 256;

/// The labels of the objects of a file: the JSON of
/// Metadata/zslice_labels.json, {"version":1,"objects":[{"object":id,
/// "labels":[...]}]}. Each label is in the frame of the mesh of its
/// object. A bad label is dropped (and counted); a bad entry is ignored.
const Labels = struct {
    objects: []const std.json.Value = &.{},
    dropped: u32 = 0,

    fn init(a: Allocator, entries: []const zipfile.Entry) Allocator.Error!Labels {
        for (entries) |e| if (std.mem.eql(u8, e.name, labels_entry)) {
            if (e.data.len > max_labels_bytes) return .{};
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, e.data, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{},
            };
            const o = switch (v) {
                .object => |x| x,
                else => return .{},
            };
            const ver = o.get("version") orelse return .{};
            if (ver != .integer or ver.integer != 1) return .{};
            const objs = o.get("objects") orelse return .{};
            if (objs != .array) return .{};
            return .{ .objects = objs.array.items };
        };
        return .{};
    }

    /// The labels of object `id`, moved by the transform `t` of its build
    /// item. The caller owns the result.
    fn take(self: *Labels, gpa: Allocator, id: u32, t: Transform) Allocator.Error![]label_mod.Label {
        var out: std.ArrayList(label_mod.Label) = .empty;
        errdefer {
            for (out.items) |*l| l.deinit(gpa);
            out.deinit(gpa);
        }
        for (self.objects) |ov| {
            if (ov != .object) continue;
            const oid = ov.object.get("object") orelse continue;
            if (oid != .integer or oid.integer != id) continue;
            const list = ov.object.get("labels") orelse continue;
            if (list != .array) continue;
            for (list.array.items) |lv| {
                if (out.items.len >= max_labels) {
                    self.dropped += 1;
                    continue;
                }
                var l = label_mod.fromValue(gpa, lv, .{}) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadLabel => {
                        self.dropped += 1;
                        continue;
                    },
                };
                // The ids are unique in a part.
                for (out.items) |o| if (o.id == l.id) {
                    l.id = 0;
                };
                if (l.id == 0) {
                    var m: u32 = 0;
                    for (out.items) |o| m = @max(m, o.id);
                    l.id = m + 1;
                }
                moveLabel(&l, t);
                if (!std.math.isFinite(l.origin[0] + l.origin[1] + l.origin[2])) {
                    l.deinit(gpa);
                    self.dropped += 1;
                    continue;
                }
                out.append(gpa, l) catch |e| {
                    l.deinit(gpa);
                    return e;
                };
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Writes the labels entry of the parts of a plate (see `Labels`), or
/// nothing if no part has a label. `ids[i]` is the object id of part i.
fn writeLabels(w: *std.Io.Writer, plate: *const plate_mod.Plate, ids: []const usize) std.Io.Writer.Error!bool {
    var any = false;
    for (plate.parts.items) |p| any = any or p.labels.items.len > 0;
    if (!any) return false;
    try w.writeAll("{\"version\":1,\"objects\":[");
    var first = true;
    for (plate.parts.items, ids) |*p, id| {
        if (p.labels.items.len == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"object\":{d},\"labels\":[", .{id});
        for (p.labels.items, 0..) |l, k| {
            if (k > 0) try w.writeByte(',');
            const m = p.meshLabel(l);
            try label_mod.write(&m, w);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}\n");
    return true;
}

/// The value of a key of a Bambu Studio <metadata key=".." value=".."/>.
fn metaValue(tag: Tag, key: []const u8) ?[]const u8 {
    const k = tag.attr("key") orelse return null;
    if (!std.mem.eql(u8, k, key)) return null;
    return tag.attr("value");
}

/// The filaments of the objects and parts of a project of Bambu Studio or
/// PrusaSlicer (see `Filaments`).
fn readFilaments(a: Allocator, entries: []const zipfile.Entry, out: *Filaments) Allocator.Error!void {
    for (entries) |e| {
        const bambu = std.mem.eql(u8, e.name, "Metadata/model_settings.config");
        const prusa = std.mem.eql(u8, e.name, "Metadata/Slic3r_PE_model.config");
        if (!bambu and !prusa) continue;
        var it: Tags = .{ .text = e.data };
        var object: ?[]const u8 = null;
        var part: ?[]const u8 = null;
        var volume: ?[2]u32 = null;
        while (it.next()) |tag| {
            if (std.mem.eql(u8, tag.name, "object")) {
                object = if (tag.closing or tag.empty) null else tag.attr("id");
            } else if (std.mem.eql(u8, tag.name, "part")) {
                part = if (tag.closing or tag.empty) null else tag.attr("id");
            } else if (std.mem.eql(u8, tag.name, "volume")) {
                volume = null;
                if (tag.closing or tag.empty) continue;
                const first = std.fmt.parseInt(u32, tag.attr("firstid") orelse continue, 10) catch continue;
                const last = std.fmt.parseInt(u32, tag.attr("lastid") orelse continue, 10) catch continue;
                volume = .{ first, last };
            } else if (std.mem.eql(u8, tag.name, "metadata")) {
                const v = metaValue(tag, "extruder") orelse continue;
                const f = std.fmt.parseInt(u8, std.mem.trim(u8, v, " "), 10) catch continue;
                const obj = object orelse continue;
                if (volume) |r| {
                    try out.volumes.append(a, .{ .object = obj, .first = r[0], .last = r[1], .filament = f });
                } else if (part) |p| {
                    try out.parts.put(a, p, f);
                } else {
                    try out.objects.put(a, obj, f);
                }
            }
        }
    }
}

/// The colors and the materials of the filaments of a project of Bambu
/// Studio (Metadata/project_settings.config, JSON: "filament_colour" and
/// "filament_type") or PrusaSlicer (Metadata/Slic3r_PE.config, lines
/// "; extruder_colour = ..." or "; filament_colour = ..." and
/// "; filament_type = ...", with ";" between the values).
fn readColors(gpa: Allocator, entries: []const zipfile.Entry, out: *Loaded) Allocator.Error!void {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "Metadata/project_settings.config")) {
            out.colors = try jsonList(gpa, e.data, "\"filament_colour\"");
            out.materials = try jsonList(gpa, e.data, "\"filament_type\"");
            return;
        }
        if (std.mem.eql(u8, e.name, "Metadata/Slic3r_PE.config")) {
            var colors = try iniList(gpa, e.data, "; extruder_colour = ");
            // An empty extruder color: the filament color.
            var any = false;
            for (colors) |c| any = any or c.len > 0;
            if (!any) {
                for (colors) |c| gpa.free(c);
                gpa.free(colors);
                colors = try iniList(gpa, e.data, "; filament_colour = ");
            }
            out.colors = colors;
            out.materials = try iniList(gpa, e.data, "; filament_type = ");
            return;
        }
    }
}

/// The texts of a JSON list of texts after `key`, or empty.
fn jsonList(gpa: Allocator, text: []const u8, key: []const u8) Allocator.Error![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |x| gpa.free(x);
        list.deinit(gpa);
    }
    const at = std.mem.indexOf(u8, text, key) orelse return list.toOwnedSlice(gpa);
    const open = std.mem.indexOfScalarPos(u8, text, at + key.len, '[') orelse return list.toOwnedSlice(gpa);
    const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return list.toOwnedSlice(gpa);
    var i = open + 1;
    while (i < close) {
        const q0 = std.mem.indexOfScalarPos(u8, text, i, '"') orelse break;
        if (q0 >= close) break;
        const q1 = std.mem.indexOfScalarPos(u8, text, q0 + 1, '"') orelse break;
        // A file has at most a few filaments: a limit for a crafted file.
        if (list.items.len >= 64) break;
        try list.append(gpa, try gpa.dupe(u8, text[q0 + 1 .. q1]));
        i = q1 + 1;
    }
    return list.toOwnedSlice(gpa);
}

/// The values of a line "key value;value;..." of an INI text, or empty.
fn iniList(gpa: Allocator, text: []const u8, key: []const u8) Allocator.Error![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |x| gpa.free(x);
        list.deinit(gpa);
    }
    const at = std.mem.indexOf(u8, text, key) orelse return list.toOwnedSlice(gpa);
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text[at + key.len .. end], " \r"), ';');
    while (it.next()) |v| {
        if (list.items.len >= 64) break;
        try list.append(gpa, try gpa.dupe(u8, std.mem.trim(u8, v, " \"")));
    }
    return list.toOwnedSlice(gpa);
}

/// Joins the parts whose boxes overlap into one part: in a 3MF file they
/// are one assembly (for example a base and its text in another color),
/// and the plate must keep them together. A part with metadata (its own
/// settings, or a modifier volume) is not joined.
pub fn joinOverlapping(gpa: Allocator, loaded: *Loaded) Allocator.Error!void {
    const n = loaded.parts.len;
    if (n < 2) return;
    const group = try gpa.alloc(usize, n);
    defer gpa.free(group);
    for (group, 0..) |*g, i| g.* = i;
    const boxes = try gpa.alloc(mesh_mod.Bounds3, n);
    defer gpa.free(boxes);
    for (loaded.parts, 0..) |*p, i| boxes[i] = p.buildBounds();
    const find = struct {
        fn f(g: []usize, i: usize) usize {
            var r = i;
            while (g[r] != r) r = g[r];
            return r;
        }
    }.f;
    for (0..n) |i| for (i + 1..n) |j| {
        // A part with its own settings (or a modifier volume) stays apart.
        if (loaded.parts[i].meta.len > 0 or loaded.parts[j].meta.len > 0) continue;
        // A part with labels stays apart: its labels are on its mesh.
        if (loaded.parts[i].labels.len > 0 or loaded.parts[j].labels.len > 0) continue;
        const a = boxes[i];
        const b = boxes[j];
        var touch = true;
        for (0..3) |k| {
            if (a.max[k] < b.min[k] - 1e-3 or b.max[k] < a.min[k] - 1e-3) touch = false;
        }
        if (touch) group[find(group, j)] = find(group, i);
    };
    var out: std.ArrayList(LoadedPart) = .empty;
    errdefer out.deinit(gpa);
    // The parts of a group go into the build, in one frame.
    for (0..n) |i| {
        const r = find(group, i);
        if (r != i) {
            loaded.parts[i].toBuild();
            loaded.parts[r].toBuild();
        }
    }
    for (0..n) |i| {
        if (find(group, i) != i) continue;
        var part = loaded.parts[i];
        loaded.parts[i].mesh = .empty;
        loaded.parts[i].name = &.{};
        loaded.parts[i].meta = &.{};
        loaded.parts[i].paint = .{};
        loaded.parts[i].labels = &.{};
        // A group of parts with other filaments or paint: the filament of
        // each part becomes the paint of its triangles.
        var mixed = !part.paint.isEmpty();
        for (i + 1..n) |j| {
            if (find(group, j) != i) continue;
            if (loaded.parts[j].filament != part.filament or !loaded.parts[j].paint.isEmpty()) mixed = true;
        }
        if (mixed and part.filament != 0) {
            try part.paint.ensure(gpa, part.mesh.faces.items.len);
            for (part.paint.states.items[0..part.mesh.faces.items.len]) |*s| if (s.* == 0) {
                s.* = part.filament;
            };
            part.filament = 0;
        }
        for (i + 1..n) |j| {
            if (find(group, j) != i) continue;
            const m = &loaded.parts[j].mesh;
            const base: u32 = @intCast(part.mesh.vertices.items.len);
            const face_base = part.mesh.faces.items.len;
            try part.mesh.vertices.appendSlice(gpa, m.vertices.items);
            try part.mesh.faces.ensureUnusedCapacity(gpa, m.faces.items.len);
            for (m.faces.items) |f| part.mesh.faces.appendAssumeCapacity(.{ f[0] + base, f[1] + base, f[2] + base });
            if (mixed) {
                const q = &loaded.parts[j];
                try part.paint.ensure(gpa, part.mesh.faces.items.len);
                for (0..m.faces.items.len) |f| {
                    const st = q.paint.stateOf(f);
                    if (st == paint_mod.split) {
                        var w: std.Io.Writer.Allocating = .init(gpa);
                        defer w.deinit();
                        q.paint.writeText(f, &w.writer) catch return error.OutOfMemory;
                        part.paint.setText(gpa, face_base + f, w.written()) catch |e| switch (e) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.BadPaint => {},
                        };
                    } else part.paint.states.items[face_base + f] = if (st != 0) st else q.filament;
                }
            }
        }
        part.settle(gpa);
        try out.append(gpa, part);
    }
    for (loaded.parts) |*p| p.deinit(gpa);
    gpa.free(loaded.parts);
    loaded.parts = try out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Write

fn writeEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

fn writeObject(w: *std.Io.Writer, id: usize, name: []const u8, meta: []const Meta, mesh: *const Mesh, paint: ?*const paint_mod.Paint) std.Io.Writer.Error!void {
    try w.print("  <object id=\"{d}\" type=\"model\" name=\"", .{id});
    try writeEscaped(w, name);
    try w.writeAll("\">\n");
    if (meta.len > 0) {
        try w.writeAll("   <metadatagroup>\n");
        for (meta) |m| {
            try w.writeAll("    <metadata name=\"");
            try writeEscaped(w, m.key);
            try w.writeAll("\" preserve=\"true\" type=\"xs:string\">");
            try writeEscaped(w, m.value);
            try w.writeAll("</metadata>\n");
        }
        try w.writeAll("   </metadatagroup>\n");
    }
    try w.writeAll("   <mesh>\n    <vertices>\n");
    for (mesh.vertices.items) |v| try w.print("     <vertex x=\"{d}\" y=\"{d}\" z=\"{d}\"/>\n", .{ v.x, v.y, v.z });
    try w.writeAll("    </vertices>\n    <triangles>\n");
    for (mesh.faces.items, 0..) |f, i| {
        try w.print("     <triangle v1=\"{d}\" v2=\"{d}\" v3=\"{d}\"", .{ f[0], f[1], f[2] });
        // The paint, in the attributes of PrusaSlicer and Bambu Studio.
        if (paint) |p| if (p.stateOf(i) != 0) {
            var buf: [4096]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&buf);
            p.writeText(i, &fw) catch {};
            try w.print(" slic3rpe:mmu_segmentation=\"{s}\" paint_color=\"{s}\"", .{ fw.buffered(), fw.buffered() });
        };
        try w.writeAll("/>\n");
    }
    try w.writeAll("    </triangles>\n   </mesh>\n  </object>\n");
}

/// Writes a 3MF file of the plate, with the overrides text.
pub fn write(gpa: Allocator, out: *std.Io.Writer, plate: *const plate_mod.Plate, overrides: []const u8) (Allocator.Error || std.Io.Writer.Error)!void {
    var model: std.Io.Writer.Allocating = .init(gpa);
    defer model.deinit();
    const w = &model.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" xmlns:cura=\"http://software.ultimaker.com/xml/cura/3mf/2015/10\" xmlns:slic3rpe=\"http://schemas.slic3r.org/3mf/2017/06\">\n");
    try w.writeAll(" <metadata name=\"Application\">zslice</metadata>\n <resources>\n");
    // One object for each part and for each of its volumes, with the
    // metadata. A volume has the transform of its part.
    var id: usize = 0;
    for (plate.parts.items) |*p| {
        id += 1;
        try writeObject(w, id, p.name, p.meta, &p.mesh, &p.paint);
        for (p.volumes.items) |*v| {
            id += 1;
            try writeObject(w, id, v.name, v.meta, &v.mesh, null);
        }
    }
    try w.writeAll(" </resources>\n <build>\n");
    id = 0;
    for (plate.parts.items) |*p| {
        const t = p.transform();
        for (0..1 + p.volumes.items.len) |_| {
            id += 1;
            try w.print("  <item objectid=\"{d}\" transform=\"", .{id});
            for (t, 0..) |x, i| try w.print("{s}{d}", .{ if (i == 0) "" else " ", x });
            try w.writeAll("\"/>\n");
        }
    }
    try w.writeAll(" </build>\n</model>\n");

    const types =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/><Default Extension="txt" ContentType="text/plain"/></Types>
        \\
    ;
    const rels =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        \\
    ;
    // The labels: the object id of each part.
    var lw: std.Io.Writer.Allocating = .init(gpa);
    defer lw.deinit();
    const ids = try gpa.alloc(usize, plate.parts.items.len);
    defer gpa.free(ids);
    id = 0;
    for (plate.parts.items, ids) |*p, *pid| {
        pid.* = id + 1;
        id += 1 + p.volumes.items.len;
    }
    const has_labels = writeLabels(&lw.writer, plate, ids) catch return error.OutOfMemory;
    const entries = [_]zipfile.Entry{
        .{ .name = "[Content_Types].xml", .data = @constCast(types) },
        .{ .name = "_rels/.rels", .data = @constCast(rels) },
        .{ .name = "3D/3dmodel.model", .data = model.written() },
        .{ .name = "Metadata/zslice_overrides.txt", .data = @constCast(overrides) },
        .{ .name = labels_entry, .data = lw.written() },
    };
    try zipfile.write(gpa, out, if (has_labels) &entries else entries[0..4]);
}

// ---- the snapshot of the history ----
//
// A history step keeps the plate as a snapshot: a zip with the mesh of
// each object in raw binary in its own entry ("mesh-<k>.bin": the vertex
// count, the face count, then x, y, z as f32 and the faces as u32), one
// binary entry with the objects ("objects.bin": the name, the metadata,
// the transform of the build item, and the index of the mesh, with each
// length first), and the overrides text. A move or a turn changes only the
// transforms. The mesh entries are stored with no deflate: a snapshot
// stays in memory, and a step must not wait. A 3MF file spends
// most of its time on the text of the vertices and on the deflate (300
// ms for a 3DBenchy). The snapshot loads to the same `Loaded` as `read`.

fn putU32(w: *std.Io.Writer, v: usize) std.Io.Writer.Error!void {
    try w.writeAll(std.mem.asBytes(&@as(u32, @intCast(v))));
}

fn putBytes(w: *std.Io.Writer, b: []const u8) std.Io.Writer.Error!void {
    try putU32(w, b.len);
    try w.writeAll(b);
}

fn meshBytes(gpa: Allocator, mesh: *const Mesh) Allocator.Error![]u8 {
    const nv = mesh.vertices.items.len;
    const nf = mesh.faces.items.len;
    const out = try gpa.alloc(u8, 8 + 12 * nv + 12 * nf);
    std.mem.writeInt(u32, out[0..4], @intCast(nv), .little);
    std.mem.writeInt(u32, out[4..8], @intCast(nf), .little);
    var o: usize = 8;
    for (mesh.vertices.items) |v| {
        for ([_]f32{ v.x, v.y, v.z }) |x| {
            std.mem.writeInt(u32, out[o..][0..4], @bitCast(x), .little);
            o += 4;
        }
    }
    for (mesh.faces.items) |f| {
        for (f) |x| {
            std.mem.writeInt(u32, out[o..][0..4], x, .little);
            o += 4;
        }
    }
    return out;
}

/// Writes the snapshot of the plate (see above).
pub fn writeSnapshot(gpa: Allocator, out: *std.Io.Writer, plate: *const plate_mod.Plate, overrides: []const u8) (Allocator.Error || std.Io.Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var entries: std.ArrayList(zipfile.Entry) = .empty;
    var objects: std.Io.Writer.Allocating = .init(a);
    const ow = &objects.writer;
    var k: usize = 0;
    for (plate.parts.items) |*p| {
        const t = p.transform();
        for (0..1 + p.volumes.items.len) |j| {
            const name = if (j == 0) p.name else p.volumes.items[j - 1].name;
            const meta = if (j == 0) p.meta else p.volumes.items[j - 1].meta;
            const mesh = if (j == 0) &p.mesh else &p.volumes.items[j - 1].mesh;
            try putBytes(ow, name);
            try putU32(ow, meta.len);
            for (meta) |m| {
                try putBytes(ow, m.key);
                try putBytes(ow, m.value);
            }
            try ow.writeAll(std.mem.sliceAsBytes(&t));
            try putU32(ow, k);
            // Stored, with no deflate: a snapshot stays in memory, and the
            // first step after a load does not wait for a deflate of the
            // mesh (220 ms for a 3DBenchy).
            try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "mesh-{d}.bin", .{k}), .data = try meshBytes(a, mesh), .store = true });
            // The paint of a part: a line "triangle text" for each painted
            // triangle.
            if (j == 0 and !p.paint.isEmpty()) {
                var pw: std.Io.Writer.Allocating = .init(a);
                for (0..p.mesh.faces.items.len) |f| if (p.paint.stateOf(f) != 0) {
                    try pw.writer.print("{d} ", .{f});
                    try p.paint.writeText(f, &pw.writer);
                    try pw.writer.writeByte('\n');
                };
                try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "paint-{d}.txt", .{k}), .data = pw.written(), .store = true });
            }
            k += 1;
        }
    }
    try entries.append(a, .{ .name = "objects.bin", .data = objects.written() });
    try entries.append(a, .{ .name = "Metadata/zslice_overrides.txt", .data = @constCast(overrides) });
    // The labels: the object of part i is mesh k + 1 (as the ids of
    // `write`).
    const ids = try a.alloc(usize, plate.parts.items.len);
    k = 0;
    for (plate.parts.items, ids) |*p, *pid| {
        pid.* = k + 1;
        k += 1 + p.volumes.items.len;
    }
    var lw: std.Io.Writer.Allocating = .init(a);
    if (writeLabels(&lw.writer, plate, ids) catch return error.OutOfMemory) try entries.append(a, .{ .name = labels_entry, .data = lw.written(), .store = true });
    try zipfile.write(gpa, out, entries.items);
}

/// True for the bytes of a snapshot (see writeSnapshot).
pub fn isSnapshot(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes[0..@min(bytes.len, 4096)], "mesh-0.bin") != null;
}

const Reader = struct {
    b: []const u8,
    o: usize = 0,
    fn u32_(r: *Reader) Error!u32 {
        if (r.o + 4 > r.b.len) return error.Corrupt;
        defer r.o += 4;
        return std.mem.readInt(u32, r.b[r.o..][0..4], .little);
    }
    fn bytes(r: *Reader) Error![]const u8 {
        const n = try r.u32_();
        // In u64: a sum in usize can wrap on wasm32.
        if (@as(u64, r.o) + n > r.b.len) return error.Corrupt;
        defer r.o += n;
        return r.b[r.o..][0..n];
    }
};

/// Reads a snapshot to the parts of a 3MF file, each mesh at its place.
pub fn readSnapshot(gpa: Allocator, bytes: []const u8, opts: ReadOptions) Error!Loaded {
    const entries = zipfile.readAll(gpa, bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
    defer zipfile.freeAll(gpa, entries);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var labels: Labels = try .init(arena_state.allocator(), entries);
    var objects: ?[]const u8 = null;
    var overrides: []const u8 = "";
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "objects.bin")) objects = e.data;
        if (std.mem.eql(u8, e.name, "Metadata/zslice_overrides.txt")) overrides = e.data;
    }
    var parts: std.ArrayList(LoadedPart) = .empty;
    errdefer {
        for (parts.items) |*p| p.deinit(gpa);
        parts.deinit(gpa);
    }
    var r: Reader = .{ .b = objects orelse return error.Corrupt };
    while (r.o < r.b.len) {
        var part: LoadedPart = .{ .name = try gpa.dupe(u8, try r.bytes()), .mesh = .empty };
        errdefer part.deinit(gpa);
        const nm = try r.u32_();
        // Each entry has at least two lengths (8 bytes) in the file.
        if (@as(u64, nm) * 8 > r.b.len - r.o) return error.Corrupt;
        part.meta = try gpa.alloc(Meta, nm);
        for (part.meta) |*m| m.* = .{ .key = &.{}, .value = &.{} };
        for (part.meta) |*m| m.* = .{ .key = try gpa.dupe(u8, try r.bytes()), .value = try gpa.dupe(u8, try r.bytes()) };
        if (r.o + 96 > r.b.len) return error.Corrupt;
        var t: Transform = undefined;
        @memcpy(std.mem.sliceAsBytes(&t), r.b[r.o..][0..96]);
        r.o += 96;
        // The mesh in the frame of the object, and its place.
        part.place = if (opts.keep_places) placeOf(t) else null;
        if (part.place != null) t = identity;
        const k = try r.u32_();
        var name_buf: [32]u8 = undefined;
        const mname = std.fmt.bufPrint(&name_buf, "mesh-{d}.bin", .{k}) catch return error.Corrupt;
        var data: ?[]const u8 = null;
        for (entries) |e| if (std.mem.eql(u8, e.name, mname)) {
            data = e.data;
        };
        const d = data orelse return error.Corrupt;
        if (d.len < 8) return error.Corrupt;
        const nv = std.mem.readInt(u32, d[0..4], .little);
        const nf = std.mem.readInt(u32, d[4..8], .little);
        if (@as(u64, d.len) != 8 + 12 * @as(u64, nv) + 12 * @as(u64, nf)) return error.Corrupt;
        try part.mesh.vertices.ensureTotalCapacity(gpa, nv);
        try part.mesh.faces.ensureTotalCapacity(gpa, nf);
        var o: usize = 8;
        for (0..nv) |_| {
            var v: [3]f64 = undefined;
            for (&v) |*x| {
                x.* = @as(f32, @bitCast(std.mem.readInt(u32, d[o..][0..4], .little)));
                o += 4;
            }
            const q = apply(t, v);
            part.mesh.vertices.appendAssumeCapacity(.{ .x = @floatCast(q[0]), .y = @floatCast(q[1]), .z = @floatCast(q[2]) });
        }
        for (0..nf) |_| {
            var f: [3]u32 = undefined;
            for (&f) |*x| {
                x.* = std.mem.readInt(u32, d[o..][0..4], .little);
                if (x.* >= nv) return error.Corrupt;
                o += 4;
            }
            part.mesh.faces.appendAssumeCapacity(f);
        }
        // The paint (see writeSnapshot).
        const pname = std.fmt.bufPrint(&name_buf, "paint-{d}.txt", .{k}) catch return error.Corrupt;
        for (entries) |e| if (std.mem.eql(u8, e.name, pname)) {
            var lines = std.mem.tokenizeScalar(u8, e.data, '\n');
            while (lines.next()) |line| {
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                const tri = std.fmt.parseInt(u32, line[0..sp], 10) catch continue;
                if (tri >= nf) continue;
                part.paint.setText(gpa, tri, line[sp + 1 ..]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadPaint => {},
                };
            }
        };
        part.labels = try labels.take(gpa, k + 1, t);
        try parts.append(gpa, part);
    }
    return .{ .parts = try parts.toOwnedSlice(gpa), .overrides = try gpa.dupe(u8, overrides), .labels_dropped = labels.dropped };
}

const testing = std.testing;

test "3mf: a plate goes out and comes back at the same places" {
    const gpa = testing.allocator;
    var plate: plate_mod.Plate = .{};
    defer plate.deinit(gpa);
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 10, 5);
    _ = try plate.add(gpa, "box & co", try b.finish(), .{ 200, 200 }, 3, false);
    var b2: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b2, -5, -5, 2, 5, 5, 12);
    _ = try plate.add(gpa, "post", try b2.finish(), .{ 200, 200 }, 3, false);
    plate.rotate(0, 30);
    plate.move(0, 60, 70);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &plate, "-100000\t100000\tproject.infill_density\t0.4\n");
    var back = try read(gpa, out.written());
    defer back.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), back.parts.len);
    try testing.expectEqualStrings("box & co", back.parts[0].name);
    try testing.expectEqualStrings("-100000\t100000\tproject.infill_density\t0.4\n", back.overrides);
    // The loaded meshes are where the combined mesh of the plate has them.
    var combined = try plate.combined(gpa);
    defer combined.deinit(gpa);
    const cb = combined.bounds();
    var lo = [3]f64{ 1e9, 1e9, 1e9 };
    var hi = [3]f64{ -1e9, -1e9, -1e9 };
    for (back.parts) |p| {
        const pb = p.mesh.bounds();
        for (0..3) |i| {
            lo[i] = @min(lo[i], pb.min[i]);
            hi[i] = @max(hi[i], pb.max[i]);
        }
    }
    for (0..3) |i| {
        try testing.expectApproxEqAbs(cb.min[i], lo[i], 1e-3);
        try testing.expectApproxEqAbs(cb.max[i], hi[i], 1e-3);
    }
}

test "3mf: overlapping parts join" {
    const gpa = testing.allocator;
    var parts = try gpa.alloc(LoadedPart, 3);
    const boxes = [_][6]f64{ .{ 0, 0, 0, 10, 10, 3 }, .{ 2, 2, 3, 8, 8, 4 }, .{ 50, 50, 0, 60, 60, 3 } };
    for (boxes, 0..) |bx, i| {
        var b: mesh_mod.Builder = .init(gpa);
        try mesh_mod.shapes.addBox(&b, bx[0], bx[1], bx[2], bx[3], bx[4], bx[5]);
        parts[i] = .{ .name = try std.fmt.allocPrint(gpa, "p{d}", .{i}), .mesh = try b.finish() };
    }
    var loaded: Loaded = .{ .parts = parts, .overrides = try gpa.dupe(u8, "") };
    defer loaded.deinit(gpa);
    try joinOverlapping(gpa, &loaded);
    try testing.expectEqual(@as(usize, 2), loaded.parts.len);
    try testing.expectEqualStrings("p0", loaded.parts[0].name);
    try testing.expectEqual(@as(usize, 24), loaded.parts[0].mesh.faces.items.len);
}

test "3mf: components and units" {
    const gpa = testing.allocator;
    const model =
        \\<?xml version="1.0"?>
        \\<model unit="centimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        \\ <resources>
        \\  <object id="1" type="model"><mesh><vertices>
        \\   <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/>
        \\  </vertices><triangles>
        \\   <triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="1" v2="2" v3="3"/><triangle v1="0" v2="3" v3="2"/>
        \\  </triangles></mesh></object>
        \\  <object id="2" type="model" name="pair"><components>
        \\   <component objectid="1"/>
        \\   <component objectid="1" transform="1 0 0 0 1 0 0 0 1 2 0 0"/>
        \\  </components></object>
        \\ </resources>
        \\ <build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 5 5 0"/></build>
        \\</model>
    ;
    const entries = [_]zipfile.Entry{.{ .name = "3D/3dmodel.model", .data = @constCast(model) }};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try zipfile.write(gpa, &out.writer, &entries);
    var back = try read(gpa, out.written());
    defer back.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), back.parts.len);
    try testing.expectEqualStrings("pair", back.parts[0].name);
    try testing.expectEqual(@as(usize, 8), back.parts[0].mesh.faces.items.len);
    // Centimeters: x from 5 cm to 5 + 2 + 1 cm = 50 to 80 mm.
    const bb = back.parts[0].mesh.bounds();
    try testing.expectApproxEqAbs(@as(f64, 50), bb.min[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 80), bb.max[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 10), bb.max[2], 1e-4);
}

test "3mf: a fan-out of components is corrupt" {
    const gpa = testing.allocator;
    // Each object has 10 components of the next: 10^12 visits of the mesh.
    var model: std.Io.Writer.Allocating = .init(gpa);
    defer model.deinit();
    const w = &model.writer;
    try w.writeAll("<?xml version=\"1.0\"?>\n<model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources>\n");
    try w.writeAll("<object id=\"0\" type=\"model\"><mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"0\" z=\"0\"/><vertex x=\"0\" y=\"1\" z=\"0\"/></vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh></object>\n");
    for (1..13) |k| {
        try w.print("<object id=\"{d}\" type=\"model\"><components>", .{k});
        for (0..10) |_| try w.print("<component objectid=\"{d}\"/>", .{k - 1});
        try w.writeAll("</components></object>\n");
    }
    try w.writeAll("</resources><build><item objectid=\"12\"/></build></model>\n");
    const entries = [_]zipfile.Entry{.{ .name = "3D/3dmodel.model", .data = model.written() }};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try zipfile.write(gpa, &out.writer, &entries);
    try testing.expectError(error.Corrupt, read(gpa, out.written()));
}

test "3mf: points that are not finite or too far are corrupt" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "1e300", "200000" }) |x| {
        var model: std.Io.Writer.Allocating = .init(gpa);
        defer model.deinit();
        try model.writer.print("<?xml version=\"1.0\"?>\n<model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources><object id=\"1\" type=\"model\"><mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"{s}\" y=\"0\" z=\"0\"/><vertex x=\"0\" y=\"1\" z=\"1\"/></vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh></object></resources><build><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 0 0 inf\"/></build></model>\n", .{x});
        const entries = [_]zipfile.Entry{.{ .name = "3D/3dmodel.model", .data = model.written() }};
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try zipfile.write(gpa, &out.writer, &entries);
        // 1e300 is not finite as f32: it reads as 0, so the part is
        // flat; 200000 mm is past the limit of a point.
        if (std.mem.eql(u8, x, "200000")) {
            try testing.expectError(error.Corrupt, read(gpa, out.written()));
        } else {
            var back = read(gpa, out.written()) catch |e| {
                try testing.expect(e == error.Corrupt or e == error.EmptyMesh);
                continue;
            };
            defer back.deinit(gpa);
            for (back.parts[0].mesh.vertices.items) |v| try testing.expect(std.math.isFinite(v.x) and std.math.isFinite(v.z));
        }
    }
}

test "3mf: a snapshot with lengths past its end is corrupt" {
    const gpa = testing.allocator;
    // objects.bin: a name of 3 bytes, then a meta count of 2^30.
    var obj: [11]u8 = undefined;
    std.mem.writeInt(u32, obj[0..4], 3, .little);
    @memcpy(obj[4..7], "abc");
    std.mem.writeInt(u32, obj[7..11], 1 << 30, .little);
    const entries = [_]zipfile.Entry{
        .{ .name = "mesh-0.bin", .data = @constCast("") },
        .{ .name = "objects.bin", .data = &obj },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try zipfile.write(gpa, &out.writer, &entries);
    try testing.expectError(error.Corrupt, readSnapshot(gpa, out.written(), .{}));
    // A name length of 2^32 - 1.
    std.mem.writeInt(u32, obj[0..4], 0xffff_ffff, .little);
    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try zipfile.write(gpa, &out2.writer, &entries);
    try testing.expectError(error.Corrupt, readSnapshot(gpa, out2.written(), .{}));
}

test "3mf: a Bambu Studio project with paint and parts of two filaments" {
    const gpa = testing.allocator;
    // A root model with one object of two parts in another file, as Bambu
    // Studio writes it. Part 2 has paint on one triangle; part 3 has
    // filament 2 in model_settings.config.
    const root =
        \\<?xml version="1.0"?>
        \\<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
        \\ <resources>
        \\  <object id="1" type="model"><components>
        \\   <component p:path="/3D/Objects/object_1.model" objectid="2"/>
        \\   <component p:path="/3D/Objects/object_1.model" objectid="3" transform="1 0 0 0 1 0 0 0 1 0 0 1"/>
        \\  </components></object>
        \\ </resources>
        \\ <build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 50 50 0"/></build>
        \\</model>
    ;
    const parts =
        \\<?xml version="1.0"?>
        \\<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        \\ <resources>
        \\  <object id="2" type="model"><mesh><vertices>
        \\   <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/>
        \\  </vertices><triangles>
        \\   <triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3" paint_color="8"/><triangle v1="1" v2="2" v3="3"/><triangle v1="0" v2="3" v3="2"/>
        \\  </triangles></mesh></object>
        \\  <object id="3" type="model"><mesh><vertices>
        \\   <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/>
        \\  </vertices><triangles>
        \\   <triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="1" v2="2" v3="3"/><triangle v1="0" v2="3" v3="2" paint_color="ZZ"/>
        \\  </triangles></mesh></object>
        \\ </resources>
        \\</model>
    ;
    const settings =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<config>
        \\  <object id="1">
        \\    <metadata key="extruder" value="1"/>
        \\    <part id="2" subtype="normal_part"><metadata key="name" value="base"/></part>
        \\    <part id="3" subtype="normal_part"><metadata key="extruder" value="2"/></part>
        \\  </object>
        \\</config>
    ;
    const project =
        \\{ "filament_colour": ["#FFFFFF", "#D93A3A"], "filament_type": ["PLA", "PETG"] }
    ;
    const entries = [_]zipfile.Entry{
        .{ .name = "3D/3dmodel.model", .data = @constCast(root) },
        .{ .name = "3D/Objects/object_1.model", .data = @constCast(parts) },
        .{ .name = "Metadata/model_settings.config", .data = @constCast(settings) },
        .{ .name = "Metadata/project_settings.config", .data = @constCast(project) },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try zipfile.write(gpa, &out.writer, &entries);
    var back = try read(gpa, out.written());
    defer back.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), back.parts.len);
    const p = &back.parts[0].paint;
    // Part 2: filament 1, and filament 2 on its painted triangle; part 3:
    // filament 2 (a bad paint text is no paint).
    try testing.expectEqual(@as(u8, 1), p.stateOf(0));
    try testing.expectEqual(@as(u8, 2), p.stateOf(1));
    for (4..8) |t| try testing.expectEqual(@as(u8, 2), p.stateOf(t));
    try testing.expectEqual(@as(usize, 2), back.colors.len);
    try testing.expectEqualStrings("#D93A3A", back.colors[1]);
    try testing.expectEqualStrings("PETG", back.materials[1]);
}

test "3mf: object metadata, and a group with settings splits into parts" {
    const gpa = testing.allocator;
    const tet =
        \\<mesh><vertices>
        \\   <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/>
        \\  </vertices><triangles>
        \\   <triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="1" v2="2" v3="3"/><triangle v1="0" v2="3" v3="2"/>
        \\  </triangles></mesh>
    ;
    const model = "<?xml version=\"1.0\"?>\n<model unit=\"millimeter\" xmlns:cura=\"http://software.ultimaker.com/xml/cura/3mf/2015/10\">\n" ++
        "<metadata name=\"Title\">not a part setting</metadata><resources>\n" ++
        "<object id=\"1\" name=\"plate\" type=\"model\"><metadatagroup><metadata name=\"cura:infill_sparse_density\" preserve=\"true\" type=\"xs:string\">=100</metadata></metadatagroup>" ++ tet ++ "</object>\n" ++
        "<object id=\"2\" name=\"window &amp; co\" type=\"model\"><metadatagroup><metadata name=\"cura:infill_mesh\">True</metadata><metadata name=\"cura:infill_angles\"> [45,135] </metadata></metadatagroup>" ++ tet ++ "</object>\n" ++
        "<object id=\"3\" name=\"group\" type=\"model\"><components><component objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 10 0 0\"/><component objectid=\"2\" transform=\"1 0 0 0 1 0 0 0 1 10 0 0\"/></components></object>\n" ++
        "</resources><build><item objectid=\"3\"/><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 50 0 0\"/></build></model>\n";
    const entries = [_]zipfile.Entry{.{ .name = "3D/3dmodel.model", .data = @constCast(model) }};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try zipfile.write(gpa, &out.writer, &entries);
    var back = try read(gpa, out.written());
    defer back.deinit(gpa);
    // The group gives two parts, and the item of object 1 a third.
    try testing.expectEqual(@as(usize, 3), back.parts.len);
    try testing.expectEqualStrings("plate", back.parts[0].name);
    try testing.expectEqualStrings("window & co", back.parts[1].name);
    try testing.expectEqual(@as(usize, 1), back.parts[0].meta.len);
    try testing.expectEqualStrings("cura:infill_sparse_density", back.parts[0].meta[0].key);
    try testing.expectEqualStrings("=100", back.parts[0].meta[0].value);
    try testing.expectEqual(@as(usize, 2), back.parts[1].meta.len);
    try testing.expectEqualStrings("[45,135]", back.parts[1].meta[1].value);
    // The component transform applies to each part.
    try testing.expectApproxEqAbs(@as(f64, 10), back.parts[1].mesh.bounds().min[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 50), back.parts[2].mesh.bounds().min[0], 1e-6);
    try testing.expectEqual(@as(usize, 1), back.parts[2].meta.len);
    // Parts with metadata do not join, also where they overlap.
    try joinOverlapping(gpa, &back);
    try testing.expectEqual(@as(usize, 3), back.parts.len);
}

test "3mf: a snapshot of the plate comes back with the same meshes at the same places" {
    const gpa = testing.allocator;
    var plate: plate_mod.Plate = .{};
    defer plate.deinit(gpa);
    var b: @import("mesh.zig").Builder = .init(gpa);
    try @import("mesh.zig").shapes.addBox(&b, 0, 0, 0, 10, 20, 5);
    _ = try plate.add(gpa, "box", try b.finish(), .{ 200, 200 }, 3, true);
    plate.rotate(0, 30);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeSnapshot(gpa, &out.writer, &plate, "edit\t1");
    try testing.expect(isSnapshot(out.written()));
    var snap = try readSnapshot(gpa, out.written(), .{});
    defer snap.deinit(gpa);
    // The same as a 3MF file of the plate gives.
    var full: std.Io.Writer.Allocating = .init(gpa);
    defer full.deinit();
    try write(gpa, &full.writer, &plate, "edit\t1");
    var ref = try read(gpa, full.written());
    defer ref.deinit(gpa);
    try testing.expectEqual(ref.parts.len, snap.parts.len);
    try testing.expectEqualStrings(ref.overrides, snap.overrides);
    for (ref.parts, snap.parts) |x, y| {
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqual(x.mesh.vertices.items.len, y.mesh.vertices.items.len);
        for (x.mesh.vertices.items, y.mesh.vertices.items) |u, v| {
            try testing.expectApproxEqAbs(u.x, v.x, 1e-4);
            try testing.expectApproxEqAbs(u.y, v.y, 1e-4);
            try testing.expectApproxEqAbs(u.z, v.z, 1e-4);
        }
    }
}
