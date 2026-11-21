//! The labels of the parts in the app (see label.zig): the changes of the
//! C API, their JSON, and the facts of a label for its card.
//!
//! The JSON of the API has the frame of each label (origin, normal,
//! right) in the frame of the part on the bed: the frame of
//! zs_app_part_mesh and of the paint session. The part keeps the frame in
//! the frame of its file mesh (see plate.Part.labels), so a move or a
//! turn of the part keeps the label on its face. A size of a shape times
//! the "stretch" of the label ([along right, along up], 1 if it is not
//! in the JSON) is its size on the bed. A label that the API adds keeps
//! its size on the bed; a later scale of the part scales it.
//!
//! The facts of a label (`Info`): from its shape alone, the thinnest
//! stroke, the smallest gap, and the sizes of text that print clean and
//! fair (label.zig, answer 3 of the design); the layers and the changes
//! that it costs, as an estimate; and after a slice of it, the changes
//! on its layers from the G-code, with their time and flush.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const Allocator = std.mem.Allocator;
const App = zs.app.App;
const label = zs.label;
const geom = zs.geom;
const Paths = geom.Paths;

pub const Error = error{ NoPart, NoLabel, BadLabel, TooMany } || Allocator.Error;

/// The most labels of a part.
pub const max_labels = 256;

/// The map of a part from the bed back to its file mesh: the inverse of
/// plate.Part.placeLabel.
fn unplace(p: *const zs.plate.Part, l: label.Label) label.Label {
    const t = p.transform();
    // The turn of the transform is a rotation: its inverse is its
    // transpose. Rows of `t` for row vectors are the rows of R^T.
    const rinv: zs.plate.M3 = .{ .{ t[0], t[1], t[2] }, .{ t[3], t[4], t[5] }, .{ t[6], t[7], t[8] } };
    var m = rinv;
    if (p.source != null) {
        // The pose is a rotation; the scale is along the axes of the file.
        var pinv: zs.plate.M3 = undefined;
        for (0..3) |i| for (0..3) |j| {
            pinv[i][j] = p.pose[j][i] / p.scale[i];
        };
        m = mul(pinv, rinv);
    }
    const tr = mulV(m, .{ t[9], t[10], t[11] });
    return zs.plate.mapLabel(l, m, .{ -tr[0], -tr[1], -tr[2] });
}

fn mul(a: zs.plate.M3, b: zs.plate.M3) zs.plate.M3 {
    var r: zs.plate.M3 = undefined;
    for (0..3) |i| for (0..3) |j| {
        r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    };
    return r;
}

fn mulV(a: zs.plate.M3, v: [3]f64) [3]f64 {
    return .{ a[0][0] * v[0] + a[0][1] * v[1] + a[0][2] * v[2], a[1][0] * v[0] + a[1][1] * v[1] + a[1][2] * v[2], a[2][0] * v[0] + a[2][1] * v[1] + a[2][2] * v[2] };
}

/// Adds a label to part i from its JSON (the frame on the bed). Returns
/// its id.
pub fn add(app: *App, i: usize, json: []const u8) Error!u32 {
    if (i >= app.plate.count()) return error.NoPart;
    const p = &app.plate.parts.items[i];
    if (p.labels.items.len >= max_labels) return error.TooMany;
    var l = label.parse(app.gpa, json, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadLabel => error.BadLabel,
    };
    errdefer l.deinit(app.gpa);
    const f = unplace(p, l);
    l.origin = f.origin;
    l.normal = f.normal;
    l.right = f.right;
    l.stretch = f.stretch;
    l.id = p.nextLabelId();
    try p.labels.ensureUnusedCapacity(app.gpa, 1);
    app.stopSlice();
    p.labels.appendAssumeCapacity(l);
    return l.id;
}

/// Replaces label `id` of part i with its JSON (the frame on the bed).
/// The label keeps its id.
pub fn update(app: *App, i: usize, id: u32, json: []const u8) Error!void {
    if (i >= app.plate.count()) return error.NoPart;
    const p = &app.plate.parts.items[i];
    const k = p.labelIndex(id) orelse return error.NoLabel;
    var l = label.parse(app.gpa, json, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadLabel => error.BadLabel,
    };
    const f = unplace(p, l);
    l.origin = f.origin;
    l.normal = f.normal;
    l.right = f.right;
    l.stretch = f.stretch;
    l.id = id;
    app.stopSlice();
    p.labels.items[k].deinit(app.gpa);
    p.labels.items[k] = l;
}

/// Removes label `id` of part i.
pub fn remove(app: *App, i: usize, id: u32) Error!void {
    if (i >= app.plate.count()) return error.NoPart;
    const p = &app.plate.parts.items[i];
    const k = p.labelIndex(id) orelse return error.NoLabel;
    app.stopSlice();
    var l = p.labels.orderedRemove(k);
    l.deinit(app.gpa);
}

/// The JSON of the labels of part i: an array of labels, each with its
/// frame on the bed and its "stretch".
pub fn writeJson(app: *const App, i: usize, w: *std.Io.Writer) (error{NoPart} || std.Io.Writer.Error)!void {
    if (i >= app.plate.count()) return error.NoPart;
    const p = &app.plate.parts.items[i];
    try w.writeByte('[');
    for (p.labels.items, 0..) |l, k| {
        if (k > 0) try w.writeByte(',');
        try writeOne(p.placeLabel(l), w);
    }
    try w.writeByte(']');
}

fn writeOne(l: label.Label, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return label.write(&l, w);
}

// ---- the facts of a label ----

pub const Kind = enum(u8) { side = 0, top = 1, bottom = 2 };

pub const Info = struct {
    kind: Kind = .side,
    /// The label has the filament of the part: it prints nothing.
    same_filament: bool = false,
    /// The thinnest stroke and the smallest gap of the shape (mm): see
    /// `shapeFacts`.
    thinnest: f64 = 0,
    gap: f64 = 0,
    /// The line width (mm) of the part, and the depth of the label.
    line_width: f64 = 0,
    depth: f64 = 0,
    /// Text: the cap height (mm) for strokes of two lines (clean) and of
    /// one line (fair). 0: no text.
    clean_size: f64 = 0,
    fair_size: f64 = 0,
    /// The weight (mm) that brings the thinnest stroke to one line, or 0.
    weight: f64 = 0,
    /// The z range of the label on the bed (mm), and its layers.
    z_min: f64 = 0,
    z_max: f64 = 0,
    layers: u32 = 0,
    /// The estimate of the changes before a slice: one for each layer of
    /// a side label (the flush planner alternates the order), or the k
    /// layers of a top or bottom label.
    estimate_changes: u32 = 0,
    /// The changes on the top face, for the hint on a side label.
    top_changes: u32 = 0,
    /// From the last slice, if it had this label.
    sliced: bool = false,
    changes: u32 = 0,
    /// The time (min) and the flush (g) of the changes: the slice, else
    /// the estimate.
    minutes: f64 = 0,
    grams: f64 = 0,
};

/// The thinnest stroke of a shape: two times the largest r so that an
/// opening by r keeps 95 % of the area. The smallest gap: two times the
/// largest r so that a closing by r adds less than 0.5 % of the area.
/// Both in mm, at most 10 mm.
pub fn shapeFacts(gpa: Allocator, s: Paths) Allocator.Error!struct { thinnest: f64, gap: f64 } {
    const area = s.areaMm2();
    if (!(area > 0)) return .{ .thinnest = 0, .gap = 0 };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lo: f64 = 0;
    var hi: f64 = 5;
    for (0..9) |_| {
        const r = (lo + hi) / 2;
        const o = try zs.offset.opening(a, s, geom.fromMm(r), .{});
        if (o.areaMm2() >= 0.95 * area) lo = r else hi = r;
        _ = arena_state.reset(.retain_capacity);
    }
    const thin = 2 * lo;
    lo = 0;
    hi = 5;
    for (0..9) |_| {
        const r = (lo + hi) / 2;
        const g = try zs.offset.offset(a, s, geom.fromMm(r), .{});
        const c = try zs.offset.offset(a, g, -geom.fromMm(r), .{});
        if (c.areaMm2() <= 1.005 * area) lo = r else hi = r;
        _ = arena_state.reset(.retain_capacity);
    }
    return .{ .thinnest = thin, .gap = 2 * lo };
}

/// The facts of label `id` of part i (see `Info`).
pub fn info(app: *const App, i: usize, id: u32) Error!Info {
    if (i >= app.plate.count()) return error.NoPart;
    const p = &app.plate.parts.items[i];
    const k = p.labelIndex(id) orelse return error.NoLabel;
    const l = p.placeLabel(p.labels.items[k]);
    const gpa = app.gpa;
    const s = app.settings;
    var out: Info = .{};
    const r = s.resolve() catch null;
    const w = if (r) |x| x.line_width else 1.05 * s.machine.nozzle_diameter;
    const lh = @max(s.project.layer_height, 0.01);
    out.line_width = w;
    out.depth = if (l.depth > 0) l.depth else w;
    out.kind = if (l.normal[2] > 0.7) .top else if (l.normal[2] < -0.7) .bottom else .side;
    const base: u32 = blk: {
        const v = app.partSetting(i, "project.filament") orelse break :blk s.project.filament;
        break :blk std.fmt.parseInt(u32, v, 10) catch s.project.filament;
    };
    out.same_filament = l.filament == base;
    var shape = label.outline(gpa, &l) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadFont => Paths.empty,
    };
    defer shape.deinit(gpa);
    const f = try shapeFacts(gpa, shape);
    out.thinnest = f.thinnest;
    out.gap = f.gap;
    // Text: the clean and fair sizes from the stem of the font.
    for (l.items) |it| if (it.shape == .text) {
        const font = zs.font.builtin();
        const ratio = zs.font.stemRatio(&font);
        out.clean_size = 2 * w / ratio;
        out.fair_size = w / ratio;
        if (out.thinnest < w) out.weight = @min(0.3, (w - out.thinnest) / 2);
        break;
    };
    // The z range on the bed: each point of the shape in the plane.
    var zlo: f64 = std.math.inf(f64);
    var zhi: f64 = -std.math.inf(f64);
    const up = l.up();
    for (shape.points.items) |q| {
        const z = l.origin[2] + geom.toMm(q.x) * l.right[2] + geom.toMm(q.y) * up[2];
        zlo = @min(zlo, z);
        zhi = @max(zhi, z);
    }
    if (!(zlo <= zhi)) {
        zlo = l.origin[2];
        zhi = l.origin[2];
    }
    const k_layers: u32 = @max(2, @as(u32, @intFromFloat(@ceil(out.depth / lh - 1e-6))));
    out.top_changes = k_layers;
    switch (out.kind) {
        .side => {
            out.z_min = zlo;
            out.z_max = zhi;
            out.layers = @intFromFloat(@max(1, @ceil((zhi - zlo) / lh)));
        },
        .top => {
            out.z_max = zhi;
            out.z_min = zlo - @as(f64, @floatFromInt(k_layers)) * lh;
            out.layers = k_layers;
        },
        .bottom => {
            out.z_min = zlo;
            out.z_max = zhi + @as(f64, @floatFromInt(k_layers)) * lh;
            out.layers = k_layers;
        },
    }
    out.estimate_changes = if (out.same_filament) 0 else out.layers;
    // The slice: the changes on the layers of the label, if the slice had
    // this label.
    var changes = out.estimate_changes;
    if (sliceHas(app, &l)) if (app.gcode()) |g| if (app.job) |*job| {
        const per = try zs.plate_job.changesPerLayer(gpa, g);
        defer gpa.free(per);
        var n: u32 = 0;
        for (per, 0..) |c, li| {
            if (li >= job.levels.len) break;
            const lv = job.levels[li];
            if (lv.z > out.z_min - 1e-6 and lv.z - lv.height < out.z_max + 1e-6) n += c;
        }
        out.sliced = true;
        out.changes = n;
        changes = n;
    };
    // The time and the flush of each change: half to the label filament,
    // half back (filaments.flushVolume of each way).
    const m = s.machine;
    const from = colorOf(app, base);
    const to = colorOf(app, l.filament);
    var flush: f64 = 0;
    if (m.filament_change == .tool) {
        flush = (zs.filaments.flushVolume(from, to, m.flush_volume, s.project.flush_multiplier) + zs.filaments.flushVolume(to, from, m.flush_volume, s.project.flush_multiplier)) / 2;
    }
    const rate = @max(s.filament.max_flow, 0.5);
    const n: f64 = @floatFromInt(changes);
    out.minutes = n * (m.change_time + flush / rate) / 60;
    out.grams = n * flush * s.filament.density / 1000;
    return out;
}

fn colorOf(app: *const App, filament: u32) []const u8 {
    if (filament < 1) return app.settings.filament.color;
    const f = zs.app.filament_slots.get(app, filament - 1) orelse return app.settings.filament.color;
    return f.color;
}

/// True if the last slice had this label (placed): the same values.
fn sliceHas(app: *const App, l: *const label.Label) bool {
    var h1 = std.hash.Wyhash.init(0);
    label.hash(l, &h1);
    const want = h1.final();
    for (app.slice_parts) |sp| for (sp.labels) |*x| {
        var h2 = std.hash.Wyhash.init(0);
        label.hash(x, &h2);
        if (h2.final() == want) return true;
    };
    return false;
}

/// The JSON of the facts of a label.
pub fn writeInfo(in: Info, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\"kind\":\"{s}\",\"same_filament\":{},\"thinnest\":{d:.3},\"gap\":{d:.3},\"line_width\":{d:.3},\"depth\":{d:.3},\"clean_size\":{d:.2},\"fair_size\":{d:.2},\"weight\":{d:.3},\"z_min\":{d:.3},\"z_max\":{d:.3},\"layers\":{d},\"estimate_changes\":{d},\"top_changes\":{d},\"sliced\":{},\"changes\":{d},\"minutes\":{d:.1},\"grams\":{d:.2}}}", .{
        @tagName(in.kind), in.same_filament, in.thinnest, in.gap, in.line_width, in.depth, in.clean_size, in.fair_size, in.weight, in.z_min, in.z_max, in.layers, in.estimate_changes, in.top_changes, in.sliced, in.changes, in.minutes, in.grams,
    });
}

/// One line of words for the card from the facts: the stroke, and the
/// size to set.
pub fn writeAdvice(in: Info, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (in.same_filament) return w.writeAll("This label has the filament of the part, so it does not show. Pick another filament.");
    const lw = in.line_width;
    if (in.thinnest >= 2 * lw - 1e-6) return w.print("Thinnest stroke {d:.2} mm: prints clean.", .{in.thinnest});
    if (in.thinnest >= lw - 1e-6) {
        try w.print("Thinnest stroke {d:.2} mm: prints, but rough.", .{in.thinnest});
    } else try w.print("Thinnest stroke {d:.2} mm: thinner than a line, so parts of it do not print.", .{in.thinnest});
    if (in.clean_size > 0) try w.print(" Make the text {d:.1} mm tall for clean strokes.", .{in.clean_size});
    if (in.weight > 0) try w.print(" A weight of {d:.2} mm makes the strokes one line wide.", .{in.weight});
}

const testing = std.testing;

test "labels: the facts of small and big text" {
    const gpa = testing.allocator;
    const f = zs.font.builtin();
    // Text 2 mm tall: strokes of about 0.4 mm. 8 mm: about 1.6 mm.
    for ([_]f64{ 2, 8 }) |size| {
        var items = [_]label.Item{.{ .shape = .{ .text = .{ .text = "VOLUME", .size = size } } }};
        const l: label.Label = .{ .items = &items };
        var s = try label.outlineWith(gpa, &l, &f);
        defer s.deinit(gpa);
        const facts = try shapeFacts(gpa, s);
        const stem = size * zs.font.stemRatio(&f);
        try testing.expect(facts.thinnest > 0.5 * stem and facts.thinnest < 1.3 * stem);
        try testing.expect(facts.gap > 0);
    }
}
