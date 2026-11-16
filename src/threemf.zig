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
//! zslice writes one object for each part (its mesh as it was loaded) and
//! one build item with the turn and the place of the part, and its changes
//! for the part and for some layers in Metadata/zslice_overrides.txt (one
//! line each: z_min, z_max, name, value, with tabs between them).
//!
//! Format: 3MF Core Specification 1.3 and the Production Extension, 3MF
//! Consortium (see REFERENCES.md). The XML reader handles the elements and
//! attributes of these files; it is not a general XML parser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const zipfile = @import("zipfile.zig");
const plate_mod = @import("plate.zig");
const Mesh = mesh_mod.Mesh;

pub const Error = error{ NotThreeMf, EmptyMesh, Corrupt, Unsupported } || Allocator.Error;

pub const LoadedPart = struct {
    name: []u8,
    /// The mesh at its place in the build (the item transform applied).
    mesh: Mesh,
};

pub const Loaded = struct {
    parts: []LoadedPart,
    /// The text of Metadata/zslice_overrides.txt, or empty.
    overrides: []u8,

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        for (self.parts) |*p| {
            gpa.free(p.name);
            p.mesh.deinit(gpa);
        }
        gpa.free(self.parts);
        gpa.free(self.overrides);
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

fn parseNum(s: ?[]const u8) f64 {
    const t = std.mem.trim(u8, s orelse return 0, " \t\r\n");
    return std.fmt.parseFloat(f64, t) catch 0;
}

fn parseTransform(s: ?[]const u8) Transform {
    const text = s orelse return identity;
    var t: Transform = identity;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i >= 12) break;
        t[i] = std.fmt.parseFloat(f64, tok) catch return identity;
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

const Object = struct {
    name: []const u8 = "",
    verts: std.ArrayList([3]f64) = .empty,
    tris: std.ArrayList([3]u32) = .empty,
    comps: std.ArrayList(Component) = .empty,
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
        } else if (std.mem.eql(u8, tag.name, "vertex")) {
            const o = cur orelse continue;
            try o.verts.append(a, .{ parseNum(tag.attr("x")), parseNum(tag.attr("y")), parseNum(tag.attr("z")) });
        } else if (std.mem.eql(u8, tag.name, "triangle")) {
            const o = cur orelse continue;
            const v1 = std.fmt.parseInt(u32, tag.attr("v1") orelse continue, 10) catch continue;
            const v2 = std.fmt.parseInt(u32, tag.attr("v2") orelse continue, 10) catch continue;
            const v3 = std.fmt.parseInt(u32, tag.attr("v3") orelse continue, 10) catch continue;
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

const Files = struct {
    a: Allocator,
    entries: []zipfile.Entry,
    parsed: std.StringHashMapUnmanaged(ModelFile) = .empty,

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
    if (depth > 16) return error.Corrupt;
    const mf = try files.model(path);
    const o = mf.objects.getPtr(id) orelse return error.Corrupt;
    const s = mf.scale;
    if (o.tris.items.len > 0) {
        const base: u32 = @intCast(out.vertices.items.len);
        try out.vertices.ensureUnusedCapacity(gpa, o.verts.items.len);
        for (o.verts.items) |v| {
            const p = apply(t, .{ v[0] * s, v[1] * s, v[2] * s });
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
        try addObject(files, gpa, out, c.path, c.id, compose(ct, t), depth + 1);
    }
}

/// Reads the parts of a 3MF file: one for each build item, in bed
/// coordinates (mm).
pub fn read(gpa: Allocator, bytes: []const u8) Error!Loaded {
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
    const mf = files.model(root) catch return error.EmptyMesh;

    var parts: std.ArrayList(LoadedPart) = .empty;
    errdefer {
        for (parts.items) |*p| {
            gpa.free(p.name);
            p.mesh.deinit(gpa);
        }
        parts.deinit(gpa);
    }
    for (mf.items.items, 0..) |item, k| {
        var m: Mesh = .empty;
        errdefer m.deinit(gpa);
        var t = item.t;
        for (9..12) |j| t[j] *= mf.scale;
        try addObject(&files, gpa, &m, item.path, item.id, t, 0);
        if (m.faces.items.len == 0) {
            m.deinit(gpa);
            continue;
        }
        const obj = (try files.model(item.path)).objects.getPtr(item.id);
        const name = if (obj != null and obj.?.name.len > 0)
            try gpa.dupe(u8, obj.?.name)
        else
            try std.fmt.allocPrint(gpa, "part {d}", .{k + 1});
        try parts.append(gpa, .{ .name = name, .mesh = m });
    }
    if (parts.items.len == 0) return error.EmptyMesh;
    var overrides: []u8 = try gpa.dupe(u8, "");
    for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/zslice_overrides.txt")) {
        gpa.free(overrides);
        overrides = try gpa.dupe(u8, e.data);
    };
    return .{ .parts = try parts.toOwnedSlice(gpa), .overrides = overrides };
}

/// Joins the parts whose boxes overlap into one part: in a 3MF file they
/// are one assembly (for example a base and its text in another color),
/// and the plate must keep them together.
pub fn joinOverlapping(gpa: Allocator, loaded: *Loaded) Allocator.Error!void {
    const n = loaded.parts.len;
    if (n < 2) return;
    const group = try gpa.alloc(usize, n);
    defer gpa.free(group);
    for (group, 0..) |*g, i| g.* = i;
    const boxes = try gpa.alloc(mesh_mod.Bounds3, n);
    defer gpa.free(boxes);
    for (loaded.parts, 0..) |p, i| boxes[i] = p.mesh.bounds();
    const find = struct {
        fn f(g: []usize, i: usize) usize {
            var r = i;
            while (g[r] != r) r = g[r];
            return r;
        }
    }.f;
    for (0..n) |i| for (i + 1..n) |j| {
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
    for (0..n) |i| {
        if (find(group, i) != i) continue;
        var part = loaded.parts[i];
        loaded.parts[i].mesh = .empty;
        loaded.parts[i].name = &.{};
        for (i + 1..n) |j| {
            if (find(group, j) != i) continue;
            const m = &loaded.parts[j].mesh;
            const base: u32 = @intCast(part.mesh.vertices.items.len);
            try part.mesh.vertices.appendSlice(gpa, m.vertices.items);
            try part.mesh.faces.ensureUnusedCapacity(gpa, m.faces.items.len);
            for (m.faces.items) |f| part.mesh.faces.appendAssumeCapacity(.{ f[0] + base, f[1] + base, f[2] + base });
        }
        try out.append(gpa, part);
    }
    for (loaded.parts) |*p| {
        gpa.free(p.name);
        p.mesh.deinit(gpa);
    }
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

/// Writes a 3MF file of the plate, with the overrides text.
pub fn write(gpa: Allocator, out: *std.Io.Writer, plate: *const plate_mod.Plate, overrides: []const u8) (Allocator.Error || std.Io.Writer.Error)!void {
    var model: std.Io.Writer.Allocating = .init(gpa);
    defer model.deinit();
    const w = &model.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n");
    try w.writeAll(" <metadata name=\"Application\">zslice</metadata>\n <resources>\n");
    for (plate.parts.items, 0..) |*p, k| {
        try w.print("  <object id=\"{d}\" type=\"model\" name=\"", .{k + 1});
        try writeEscaped(w, p.name);
        try w.writeAll("\">\n   <mesh>\n    <vertices>\n");
        for (p.mesh.vertices.items) |v| try w.print("     <vertex x=\"{d}\" y=\"{d}\" z=\"{d}\"/>\n", .{ v.x, v.y, v.z });
        try w.writeAll("    </vertices>\n    <triangles>\n");
        for (p.mesh.faces.items) |f| try w.print("     <triangle v1=\"{d}\" v2=\"{d}\" v3=\"{d}\"/>\n", .{ f[0], f[1], f[2] });
        try w.writeAll("    </triangles>\n   </mesh>\n  </object>\n");
    }
    try w.writeAll(" </resources>\n <build>\n");
    for (plate.parts.items, 0..) |*p, k| {
        const t = p.transform();
        try w.print("  <item objectid=\"{d}\" transform=\"", .{k + 1});
        for (t, 0..) |x, i| try w.print("{s}{d}", .{ if (i == 0) "" else " ", x });
        try w.writeAll("\"/>\n");
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
    const entries = [_]zipfile.Entry{
        .{ .name = "[Content_Types].xml", .data = @constCast(types) },
        .{ .name = "_rels/.rels", .data = @constCast(rels) },
        .{ .name = "3D/3dmodel.model", .data = model.written() },
        .{ .name = "Metadata/zslice_overrides.txt", .data = @constCast(overrides) },
    };
    try zipfile.write(gpa, out, &entries);
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
