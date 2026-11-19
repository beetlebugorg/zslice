//! The zslice command line tool.
//!
//! The tool reads files, so it gives the core a profile resolver that finds
//! profile files on disk (see `FileResolver`).

const std = @import("std");
const Io = std.Io;
const zslice = @import("zslice");
const profile = zslice.profile;

const usage =
    \\Usage:
    \\  zslice slice <model.stl|model.3mf> [options] [-o out.gcode]
    \\  zslice preview <model.stl|model.3mf> --layer N [options] [-o out.svg]
    \\  zslice gaps <model.stl> [--layer N] [options]
    \\  zslice check <model.stl> [options]
    \\  zslice orient <model.stl> [options]
    \\  zslice profiles
    \\  zslice printers
    \\  zslice profile <machine|filament|project> [options]
    \\  zslice import cura <stack folder> -o <profiles folder>
    \\  zslice settings
    \\  zslice demo <out.stl>
    \\  zslice bench <model.stl> [options]
    \\  zslice sweep <model.stl> [options] [--points N] [--only TEXT] [-o out.tsv]
    \\  zslice gcode <file.gcode>
    \\
    \\Commands:
    \\  slice     Slice a model and write G-code (default output: stdout).
    \\  preview   Write an SVG picture of one layer.
    \\  check     The printability check: lines over the flow limit of the
    \\            hot end, layers that cool too little, overhangs with no
    \\            support, islands, and layers with many retractions.
    \\  orient    List the orientations that smart placement compares, with
    \\            the parts of the cost of each, and the best one.
    \\  gaps      List the gaps of one layer (or of all layers): the areas
    \\            that should be solid and that no bead covers, with their
    \\            size and the features around them.
    \\  profiles  List the built-in profiles and where profile files go.
    \\  printers  List the printers of the printer library: the id, the
    \\            firmware, the bed ("heated", "round"), and the name.
    \\            -m ID loads the machine profile of a printer.
    \\  profile   Write the settings of one group as a profile file, with
    \\            the options applied. Start a new profile from this output.
    \\  import    Convert a Cura profile stack (a folder with cura.json, as in
    \\            the printdeck profiles) to zslice profiles. The output folder
    \\            gets machine/, filament/, and project/ files.
    \\  settings  List all settings and their default values.
    \\  gcode     Read a G-code file as the print view does (any slicer):
    \\            print the layers, the moves, the box, the time, the
    \\            time to read it, and the peak memory.
    \\  demo      Write the demo part as an STL file.
    \\  bench     Slice in the app core: once from the start, then again
    \\            after a change of each kind of setting. Print the times
    \\            and the peak memory. --only KIND times one kind: full,
    \\            late, walls, top, width, height, support, area, tree, xy,
    \\            speed, accel, flow, fan, temp, cool, cancel, or sim
    \\            (the simulated print of the plastic; sim-side and
    \\            sim-flip turn the part on its side or upside down
    \\            first, for steep overhangs). --only
    \\            patch changes each setting that needs no new plan, and
    \\            compares the G-code with a new slice. --runs N sets
    \\            the slices of each kind (default 6).
    \\  sweep     For each project and filament setting, slice with values
    \\            across its range (the others at their base values), and
    \\            write the print time, the plastic, the cost, the travel,
    \\            and the retractions of each slice as TSV. Then list the
    \\            settings that change the time and the cost the most.
    \\            --points N sets the values of a number (default 5);
    \\            --only TEXT sweeps only the settings with TEXT in their
    \\            name.
    \\
    \\Options:
    \\  -m, --machine NAME   Load a machine profile (a name or a .toml path).
    \\  -f, --filament NAME  Load a filament profile.
    \\  -p, --project NAME   Load a project profile.
    \\  -s group.name=value  Change one setting. Goes after the profiles.
    \\  -o FILE              The output file.
    \\
    \\Example:
    \\  zslice slice part.stl -m generic -f generic-petg -p fine -s project.wall_count=3 -o part.gcode
    \\
;

const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    layer: ?usize = null,
    machine: ?[]const u8 = null,
    filament: ?[]const u8 = null,
    project: ?[]const u8 = null,
    sets: std.ArrayList([]const u8) = .empty,
    /// bench: time only the changes of this kind (a key of bench_changes,
    /// or "full").
    only: ?[]const u8 = null,
    /// bench: the slices of each kind.
    runs: usize = 6,
    /// bench: the copies of the model on the plate (arranged).
    copies: usize = 1,
    /// sweep: the values of a number setting.
    points: usize = 5,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_w: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err = &stderr_w.interface;
    defer err.flush() catch {};

    if (args.len < 2) fail(err, "{s}", .{usage});
    const cmd = args[1];

    var resolver_state: FileResolver = .{ .io = io, .config_dir = configDir(arena, init.environ_map) };
    const resolver: profile.Resolver = .{ .ctx = &resolver_state, .load = FileResolver.load };

    if (std.mem.eql(u8, cmd, "settings")) {
        var buf: [4096]u8 = undefined;
        var out_w: Io.File.Writer = .init(.stdout(), io, &buf);
        try listSettings(&out_w.interface);
        try out_w.interface.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "profiles")) {
        var buf: [4096]u8 = undefined;
        var out_w: Io.File.Writer = .init(.stdout(), io, &buf);
        const w = &out_w.interface;
        try w.writeAll("Built-in profiles:\n");
        for ([_]profile.Group{ .machine, .filament, .project }) |g| {
            try w.print("  {s}:", .{@tagName(g)});
            for (profile.builtins) |b| if (b.group == g) try w.print(" {s}", .{b.name});
            try w.writeAll("\n");
        }
        try w.writeAll("\nProfile files (name.toml) are found in, in this order:\n");
        try w.writeAll("  ./profiles/<group>/\n");
        if (resolver_state.config_dir) |d| try w.print("  {s}/profiles/<group>/\n", .{d});
        try w.writeAll("  the built-in profiles\n  the printer library (machine: an id of `zslice printers`)\n\nA path with a / or a .toml name also works: -f ./my-pla.toml\n");
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "printers")) {
        var buf: [4096]u8 = undefined;
        var out_w: Io.File.Writer = .init(.stdout(), io, &buf);
        const w = &out_w.interface;
        const lib = try zslice.printers.Library.parse(gpa, zslice.printers.builtin_data);
        defer lib.deinit();
        for (lib.models) |m| {
            const flags = [_][]const u8{ if (m.heated_bed) "heated " else "", if (m.round) "round " else "" };
            const f = try std.mem.concat(arena, u8, &flags);
            try w.print("{s}\t{s}\t{s}\t{s}\n", .{ m.id, m.firmware, std.mem.trimEnd(u8, f, " "), m.title });
        }
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "import")) {
        if (args.len != 6 or !std.mem.eql(u8, args[2], "cura") or !std.mem.eql(u8, args[4], "-o")) fail(err, "{s}", .{usage});
        try importCura(arena, io, err, args[3], args[5]);
        return;
    }

    if (std.mem.eql(u8, cmd, "gcode")) {
        if (args.len != 3) fail(err, "{s}", .{usage});
        try gcodeInfo(gpa, io, err, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "demo")) {
        if (args.len != 3) fail(err, "{s}", .{usage});
        var m = try zslice.mesh.shapes.demo(gpa);
        defer m.deinit(gpa);
        try writeOut(io, args[2], m, struct {
            fn f(mesh: zslice.mesh.Mesh, w: *Io.Writer) !void {
                try mesh.writeStl(w);
            }
        }.f);
        return;
    }

    const is_profile = std.mem.eql(u8, cmd, "profile");
    const is_bench = std.mem.eql(u8, cmd, "bench");
    const is_sweep = std.mem.eql(u8, cmd, "sweep");
    const is_gaps = std.mem.eql(u8, cmd, "gaps");
    const is_check = std.mem.eql(u8, cmd, "check");
    const is_orient = std.mem.eql(u8, cmd, "orient");
    if (!is_bench and !is_sweep and !is_gaps and !is_check and !is_orient and !std.mem.eql(u8, cmd, "slice") and !std.mem.eql(u8, cmd, "preview") and !is_profile) {
        fail(err, "unknown command: {s}\n\n{s}", .{ cmd, usage });
    }

    var opts: Options = .{};
    try parseOptions(arena, err, args[2..], &opts);

    // The settings: the profiles, in order, then the -s changes.
    var settings: zslice.Settings = .{};
    // {job_name} in the start G-code is the model file name.
    if (opts.input) |in| settings.engine.job_name = std.fs.path.basename(in);
    var diag: profile.Diagnostic = .{};
    const loads = [_]struct { group: profile.Group, name: ?[]const u8 }{
        .{ .group = .machine, .name = opts.machine },
        .{ .group = .filament, .name = opts.filament },
        .{ .group = .project, .name = opts.project },
    };
    for (loads) |l| {
        const name = l.name orelse continue;
        profile.load(arena, &settings, l.group, name, resolver, &diag) catch |e| {
            if (diag.line > 0) {
                fail(err, "{s} profile \"{s}\", line {d}: {s} ({s})\n", .{ @tagName(l.group), diag.profile, diag.line, diag.message, @errorName(e) });
            }
            fail(err, "{s} profile \"{s}\": {s} ({s})\n", .{ @tagName(l.group), diag.profile, diag.message, @errorName(e) });
        };
    }
    for (opts.sets.items) |v| {
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse fail(err, "-s needs group.name=value: {s}\n", .{v});
        settings.set(v[0..eq], v[eq + 1 ..]) catch |e| fail(err, "{s}: {s}\n", .{ v, @errorName(e) });
    }

    if (is_profile) {
        const group_name = opts.input orelse fail(err, "profile needs a group: machine, filament, or project\n", .{});
        const group = std.meta.stringToEnum(profile.Group, group_name) orelse fail(err, "unknown group: {s}\n", .{group_name});
        const Ctx = struct { s: zslice.Settings, g: profile.Group };
        try writeOut(io, opts.output, Ctx{ .s = settings, .g = group }, struct {
            fn f(c: Ctx, w: *Io.Writer) !void {
                try profile.write(c.s, c.g, w);
            }
        }.f);
        return;
    }

    const in_path = opts.input orelse fail(err, "{s}", .{usage});
    const bytes = try Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .unlimited);
    if (is_check) {
        defer gpa.free(bytes);
        const app = try zslice.app.App.create(gpa, null, null);
        defer app.destroy();
        app.settings = settings;
        try app.loadStl(std.fs.path.basename(in_path), bytes);
        _ = try benchSlice(app, io);
        const r = try app.checks();
        const kinds = [_][]const u8{ "flow", "cooling", "overhang", "island", "retractions", "bridge" };
        const sev = [_][]const u8{ "note", "warning", "problem" };
        for (r.issues) |i| try err.print("{s} {s}: {s}\n", .{ sev[i.severity], kinds[@intFromEnum(i.kind)], r.textOf(i) });
        try err.print("{d} issues\n", .{r.issues.len});
        return;
    }
    if (is_orient) {
        defer gpa.free(bytes);
        const app = try zslice.app.App.create(gpa, null, null);
        defer app.destroy();
        try app.loadStl(std.fs.path.basename(in_path), bytes);
        const mesh = &app.plate.parts.items[0].mesh;
        const o = zslice.orient;
        var adj = try o.Adjacency.init(gpa, mesh);
        defer adj.deinit(gpa);
        const zs = try gpa.alloc(f64, mesh.vertices.items.len);
        defer gpa.free(zs);
        var cands: std.ArrayList([3]f64) = .empty;
        defer cands.deinit(gpa);
        try o.candidates(gpa, mesh, null, &cands);
        try err.print("down direction            overhang  contact islands  island$  contact$  height      cost\n", .{});
        for (cands.items) |d| {
            const sc = o.scoreWith(mesh, &adj, zs, d, settings.project.support_angle);
            try err.print("{d:6.3} {d:6.3} {d:6.3}  {d:9.1} {d:8.1} {d:7} {d:8.1} {d:9.1} {d:7.1} {d:9.1}\n", .{ d[0], d[1], d[2], sc.overhang, sc.contact, sc.islands, sc.island_cost, sc.contact_cost, sc.height, sc.cost });
        }
        const b = try o.best(gpa, mesh, settings.project.support_angle);
        try err.print("best: {d:.3} {d:.3} {d:.3} (cost {d:.1})\n", .{ b.dir[0], b.dir[1], b.dir[2], b.cost });
        return;
    }
    if (is_bench) {
        defer gpa.free(bytes);
        try bench(gpa, io, err, in_path, bytes, settings, opts.only, opts.runs, opts.copies);
        return;
    }
    // A 3MF file: each part that prints is a part of the plate job, with
    // its settings and its modifier volumes (see part_settings.zig and
    // plate_job.zig). The parts that print also make one mesh, for the
    // sweep.
    var loaded: ?zslice.threemf.Loaded = null;
    defer if (loaded) |*l| l.deinit(gpa);
    const is_3mf = bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04");
    var m = if (is_3mf) blk: {
        loaded = zslice.threemf.read(gpa, bytes) catch |e| {
            gpa.free(bytes);
            fail(err, "{s}: {s}\n", .{ in_path, @errorName(e) });
        };
        try zslice.threemf.joinOverlapping(gpa, &loaded.?);
        var all: zslice.Mesh = .empty;
        for (loaded.?.parts) |p| if (zslice.part_settings.prints(p.meta)) {
            const base: u32 = @intCast(all.vertices.items.len);
            try all.vertices.appendSlice(gpa, p.mesh.vertices.items);
            for (p.mesh.faces.items) |f| try all.faces.append(gpa, .{ f[0] + base, f[1] + base, f[2] + base });
        };
        break :blk all;
    } else zslice.Mesh.fromStl(gpa, bytes) catch |e| {
        gpa.free(bytes);
        fail(err, "{s}: {s}\n", .{ in_path, @errorName(e) });
    };
    // The mesh has its own copy of the data, so the file buffer can go now.
    gpa.free(bytes);
    defer m.deinit(gpa);
    var parts_plan: ?zslice.part_settings.Plan = null;
    defer if (parts_plan) |*pp| pp.deinit();
    var part_inputs: std.ArrayList(zslice.plate_job.PartInput) = .empty;
    if (loaded) |l| {
        const inputs = try arena.alloc(zslice.part_settings.Input, l.parts.len);
        for (l.parts, inputs) |*p, *in| in.* = .{ .name = p.name, .meta = p.meta, .mesh = &p.mesh };
        parts_plan = try zslice.part_settings.plan(gpa, inputs, &settings);
        try parts_plan.?.applyBase(&settings);
        for (parts_plan.?.notes) |n| try err.print("note: {s}\n", .{n});
        for (parts_plan.?.parts) |pp| try part_inputs.append(arena, .{
            .mesh = &l.parts[pp.input].mesh,
            .changes = pp.changes,
            .modifiers = pp.modifiers,
            .part = @intCast(pp.input),
        });
    } else {
        try part_inputs.append(arena, .{ .mesh = &m, .part = 0 });
    }

    if (is_sweep) {
        try sweep(gpa, io, err, &m, settings, opts);
        return;
    }

    const t0 = Io.Clock.awake.now(io);
    // One slice: the memos need not stay (see Job.keep_memos).
    var job = zslice.PlateJob.init(gpa, settings, part_inputs.items, .{ .keep_memos = false }) catch |e| fail(err, "slice failed: {s}\n", .{@errorName(e)});
    defer job.deinit();
    const pass1 = t0.untilNow(io, .awake);

    if (is_gaps) {
        const first: usize = opts.layer orelse 0;
        const last: usize = if (opts.layer) |l| l + 1 else job.layerCount();
        if (first >= job.layerCount()) fail(err, "the part has {d} layers\n", .{job.layerCount()});
        var total: usize = 0;
        var area: f64 = 0;
        for (first..@min(last, job.layerCount())) |li| {
            var lp = try job.planLayer(li);
            defer lp.deinit();
            var r = try zslice.gaps.find(gpa, &lp, .{});
            defer r.deinit(gpa);
            for (r.gaps) |g| {
                total += 1;
                area += g.area;
                if (opts.layer == null and total > 40) continue;
                try err.print("layer {d}: {d:.3} mm2, {d:.2} mm wide, at {d:.2}, {d:.2}{s}, next to", .{ li + 1, g.area, g.width, g.x, g.y, if (g.at_edge) " (edge)" else "" });
                inline for (@typeInfo(zslice.settings.Feature).@"enum".fields) |f| {
                    if (g.features & (@as(u32, 1) << f.value) != 0) try err.print(" {s}", .{f.name});
                }
                try err.print("\n", .{});
            }
        }
        try err.print("{d} gaps, {d:.2} mm2 in all\n", .{ total, area });
        return;
    }

    if (std.mem.eql(u8, cmd, "preview")) {
        const n = opts.layer orelse fail(err, "preview needs --layer N\n", .{});
        if (n >= job.layerCount()) fail(err, "the part has {d} layers\n", .{job.layerCount()});
        var lp = try job.planLayer(n);
        defer lp.deinit();
        try writeOut(io, opts.output, &lp, struct {
            fn f(plan: *zslice.layer.LayerPlan, w: *Io.Writer) !void {
                try zslice.svg.writeLayer(w, plan);
            }
        }.f);
        return;
    }

    const stats = try writeOut(io, opts.output, &job, struct {
        fn f(j: *zslice.PlateJob, w: *Io.Writer) !zslice.Stats {
            return j.writeGcode(w);
        }
    }.f);
    const elapsed = t0.untilNow(io, .awake);
    const ms = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / 1e6;
    const ms1 = @as(f64, @floatFromInt(pass1.toNanoseconds())) / 1e6;
    try err.print("{d} layers, {d:.2} m filament ({d:.1} g), about {d:.0} min, sliced in {d:.0} ms (outlines {d:.0} ms, plan and G-code {d:.0} ms)\n", .{
        stats.layer_count,
        stats.filament_mm / 1000,
        stats.filament_g,
        stats.print_time_s / 60,
        ms,
        ms1,
        ms - ms1,
    });
}

/// The sweep (see app/sweep.zig): a TSV row for each slice, progress on
/// stderr, and at the end the settings that change the time and the cost
/// the most.
fn sweep(gpa: std.mem.Allocator, io: Io, err: *Io.Writer, mesh: *const zslice.Mesh, settings: zslice.Settings, opts: Options) !void {
    var out_file: ?Io.File = null;
    defer if (out_file) |f| f.close(io);
    if (opts.output) |p| out_file = try Io.Dir.cwd().createFile(io, p, .{});
    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(out_file orelse .stdout(), io, &out_buf);
    const out = &out_w.interface;
    try out.writeAll("setting\tvalue\ttime_s\tfilament_g\tcost\ttravel_mm\tretractions\tlayers\tstatus\n");
    // The range of time and cost of each setting, for the summary.
    const Span = struct { name: []const u8, t_min: f64, t_max: f64, c_min: f64, c_max: f64 };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Ctx = struct {
        out: *Io.Writer,
        err: *Io.Writer,
        arena: std.mem.Allocator,
        spans: std.ArrayList(Span) = .empty,
        base_time: f64 = 0,
        base_cost: f64 = 0,
        failed: bool = false,
        fn add(ctx: ?*anyopaque, r: zslice.app.sweep.Result, done: usize, total: usize) void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.write(r, done, total) catch {
                c.failed = true;
            };
        }
        fn write(c: *@This(), r: zslice.app.sweep.Result, done: usize, total: usize) !void {
            const name = if (r.base) "(base)" else r.name;
            if (r.failure) |e| {
                try c.out.print("{s}\t{s}\t\t\t\t\t\t\t{s}\n", .{ name, r.value, @errorName(e) });
            } else {
                try c.out.print("{s}\t{s}\t{d:.1}\t{d:.2}\t{d:.3}\t{d:.0}\t{d}\t{d}\tok\n", .{ name, r.value, r.time_s, r.filament_g, r.cost, r.travel_mm, r.retractions, r.layers });
            }
            if (r.base) {
                c.base_time = r.time_s;
                c.base_cost = r.cost;
            } else if (r.failure == null) {
                const last = if (c.spans.items.len > 0) &c.spans.items[c.spans.items.len - 1] else null;
                if (last != null and std.mem.eql(u8, last.?.name, r.name)) {
                    last.?.t_min = @min(last.?.t_min, r.time_s);
                    last.?.t_max = @max(last.?.t_max, r.time_s);
                    last.?.c_min = @min(last.?.c_min, r.cost);
                    last.?.c_max = @max(last.?.c_max, r.cost);
                } else {
                    // The base value is part of each range.
                    try c.spans.append(c.arena, .{ .name = r.name, .t_min = @min(c.base_time, r.time_s), .t_max = @max(c.base_time, r.time_s), .c_min = @min(c.base_cost, r.cost), .c_max = @max(c.base_cost, r.cost) });
                }
            }
            try c.err.print("\rsweep: {d}/{d} slices", .{ done, total });
            try c.err.flush();
        }
    };
    var ctx: Ctx = .{ .out = out, .err = err, .arena = arena };
    try zslice.app.sweep.run(gpa, mesh, settings, .{ .points = opts.points, .filter = opts.only }, .{ .ctx = &ctx, .result = Ctx.add });
    try out.flush();
    if (ctx.failed) fail(err, "\nsweep: the output failed\n", .{});
    try err.print("\nBase: {d:.1} min, cost {d:.2}.\n", .{ ctx.base_time / 60, ctx.base_cost });
    const lists = [_]struct { title: []const u8, time: bool }{ .{ .title = "print time", .time = true }, .{ .title = "cost", .time = false } };
    for (lists) |l| {
        std.mem.sort(Span, ctx.spans.items, l.time, struct {
            fn lt(time: bool, a: Span, b: Span) bool {
                return if (time) a.t_max - a.t_min > b.t_max - b.t_min else a.c_max - a.c_min > b.c_max - b.c_min;
            }
        }.lt);
        try err.print("\nThe settings that change the {s} the most:\n", .{l.title});
        for (ctx.spans.items[0..@min(12, ctx.spans.items.len)]) |sp| {
            if (l.time) {
                try err.print("  {s:<40} {d:>7.1} to {d:>7.1} min\n", .{ sp.name, sp.t_min / 60, sp.t_max / 60 });
            } else {
                try err.print("  {s:<40} {d:>7.2} to {d:>7.2}\n", .{ sp.name, sp.c_min, sp.c_max });
            }
        }
    }
}

/// The changes that `bench` makes, one for each kind of setting. Each slice
/// gets a new value, as when a user moves a slider.
const bench_changes = [_]struct { key: []const u8, kind: []const u8, name: []const u8, values: [6][]const u8 }{
    .{ .key = "late", .kind = "late (infill)", .name = "project.infill_density", .values = .{ "0.21", "0.22", "0.23", "0.24", "0.25", "0.26" } },
    .{ .key = "walls", .kind = "wall count", .name = "project.wall_count", .values = .{ "3", "4", "5", "6", "7", "8" } },
    .{ .key = "top", .kind = "top thickness", .name = "project.top_thickness", .values = .{ "1.0", "1.2", "1.4", "1.6", "1.8", "2.0" } },
    .{ .key = "width", .kind = "line width", .name = "project.line_width", .values = .{ "0.45", "0.46", "0.47", "0.48", "0.49", "0.5" } },
    .{ .key = "height", .kind = "layer height", .name = "project.layer_height", .values = .{ "0.21", "0.22", "0.23", "0.24", "0.25", "0.26" } },
    .{ .key = "support", .kind = "support (tree angle)", .name = "project.support_tree_angle", .values = .{ "41", "42", "43", "44", "45", "46" } },
    // A support area of the editor: each slice moves its top a little, as
    // a drag of a point does (see benchArea).
    .{ .key = "area", .kind = "support area", .name = "", .values = .{ "", "", "", "", "", "" } },
    // A drag of a node of the support trees of the user (see benchTree).
    .{ .key = "tree", .kind = "tree node", .name = "", .values = .{ "", "", "", "", "", "" } },
    .{ .key = "xy", .kind = "xy offset", .name = "filament.xy_offset", .values = .{ "0.01", "0.02", "0.03", "0.04", "0.05", "0.06" } },
    // Settings that change no path: the slice runs from the move streams
    // (see settings.patch_settings).
    .{ .key = "speed", .kind = "wall speed", .name = "project.outer_wall_speed", .values = .{ "0.41", "0.42", "0.43", "0.44", "0.45", "0.46" } },
    .{ .key = "accel", .kind = "wall accel", .name = "project.outer_wall_accel", .values = .{ "810", "820", "830", "840", "850", "860" } },
    .{ .key = "flow", .kind = "flow ratio", .name = "filament.flow_ratio", .values = .{ "0.95", "0.96", "0.97", "0.98", "0.99", "1.01" } },
    .{ .key = "fan", .kind = "fan speed", .name = "filament.fan_speed", .values = .{ "0.81", "0.82", "0.83", "0.84", "0.85", "0.86" } },
    .{ .key = "temp", .kind = "nozzle temp", .name = "filament.nozzle_temp", .values = .{ "211", "212", "213", "214", "215", "216" } },
    .{ .key = "cool", .kind = "layer time", .name = "filament.min_layer_time", .values = .{ "7", "8", "9", "10", "11", "12" } },
};

/// The most slices of one kind in a bench.
const max_runs = 64;

/// Slices in the app core, as the app does after each change of a setting,
/// and prints the time of each slice and the peak memory (VmHWM).
fn bench(backing: std.mem.Allocator, io: Io, err: *Io.Writer, name: []const u8, bytes: []const u8, settings: zslice.Settings, only: ?[]const u8, runs: usize, copies: usize) !void {
    const App = zslice.app.App;
    var counter: CountingAllocator = .{ .backing = backing };
    const gpa = counter.allocator();
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    app.settings = settings;
    var times_buf: [max_runs]Sample = undefined;
    const times = times_buf[0..runs];
    if (only != null and std.mem.startsWith(u8, only.?, "sim")) {
        try app.loadStl(std.fs.path.basename(name), bytes);
        try addCopies(app, name, bytes, copies);
        // sim-side: the part on its side, for steep overhangs. sim-flip:
        // upside down.
        if (std.mem.eql(u8, only.?, "sim-side")) try app.turnPart(0, 0, 90);
        if (std.mem.eql(u8, only.?, "sim-flip")) try app.turnPart(0, 0, 180);
        _ = try benchSlice(app, io);
        try benchSim(app, io, err, &counter, times);
        try err.print("peak memory: {d} MB resident (VmHWM), {d} MB allocated\n", .{ peakMb(io), counter.peak.load(.monotonic) >> 20 });
        return;
    }
    if (only == null or std.mem.eql(u8, only.?, "full")) {
        // The first slice has no cache. Each one starts new.
        for (times) |*t| {
            // A new model drops the regions of the slice before.
            try app.loadStl(std.fs.path.basename(name), bytes);
            try addCopies(app, name, bytes, copies);
            t.* = try benchSlice(app, io);
        }
        try printTimes(err, "full slice", times);
    } else {
        try app.loadStl(std.fs.path.basename(name), bytes);
        try addCopies(app, name, bytes, copies);
    }
    for (bench_changes) |c| {
        if (only) |o| if (!std.mem.eql(u8, o, c.key)) continue;
        // Start from the base settings, with a slice that is not timed.
        app.settings = settings;
        _ = try benchSlice(app, io);
        if (std.mem.eql(u8, c.key, "tree")) {
            try benchTree(app, io, err, times);
            continue;
        }
        if (c.name.len == 0) {
            // A tree area over all of the bed, from z 1 to z 4 (and a
            // little more on each slice).
            const pts = [_][3]f64{ .{ -1000, -1000, 1 }, .{ 2000, -1000, 1 }, .{ 2000, 2000, 1 }, .{ -1000, 2000, 1 } };
            const idx = try app.areas.add(gpa, .tree, &pts, 1, 4);
            _ = try benchSlice(app, io);
            for (times, 0..) |*t, k| {
                try app.areas.set(gpa, idx, &pts, 1, 4 + 0.2 * @as(f64, @floatFromInt(k % 6 + 1)));
                t.* = try benchSlice(app, io);
            }
            try app.areas.remove(gpa, idx);
            try printTimes(err, c.kind, times);
            continue;
        }
        for (times, 0..) |*t, k| {
            // The values repeat after 6 slices. Go back to the base
            // settings between the rounds, so that each slice has a new
            // value.
            if (k > 0 and k % c.values.len == 0) {
                app.settings = settings;
                _ = try benchSlice(app, io);
            }
            try app.setSetting(c.name, c.values[k % c.values.len]);
            t.* = try benchSlice(app, io);
        }
        try printTimes(err, c.kind, times);
    }
    if (only != null and std.mem.eql(u8, only.?, "patch")) try benchPatch(gpa, app, io, err, name, bytes, settings);
    if (only == null or std.mem.eql(u8, only.?, "cancel")) try benchCancel(app, io, err, settings);
    try err.print("peak memory: {d} MB resident (VmHWM), {d} MB allocated\n", .{ peakMb(io), counter.peak.load(.monotonic) >> 20 });
}

/// The edits of the support trees of the user: a node of the first part
/// (with a segment of 20 layers or more under it) moves by 0.3 mm on each
/// run, as in a drag. Prints the time of the
/// edit (the view shows it at once) and of the slice after it. The trees
/// go after the runs. Needs tree support in the settings.
fn benchTree(app: *zslice.app.App, io: Io, err: *Io.Writer, times: []Sample) !void {
    const st = zslice.app.support_trees;
    const v = st.view(app, 0) orelse return error.SliceFailed;
    var node: ?u32 = null;
    for (v.sk.nodes.items, 0..) |nd, k| if (!nd.tip and nd.down != zslice.support_skeleton.none and nd.layer >= v.sk.nodes.items[nd.down].layer + 20) {
        node = @intCast(k);
        break;
    };
    const k = node orelse {
        try err.print("tree node: no trees\n", .{});
        return;
    };
    const x0 = (v.dx + v.sk.nodes.items[k].x) / 1000;
    const y0 = (v.dy + v.sk.nodes.items[k].y) / 1000;
    var edits: [max_runs]Sample = undefined;
    for (times, 0..) |*t, i| {
        const dx: f64 = if (i % 2 == 0) 0.3 else 0;
        const t0 = Io.Clock.awake.now(io);
        _ = try st.moveNode(app, 0, k, x0 + dx, y0);
        const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
        edits[i] = .{ .wall = ms, .cpu = ms, .faults = 0 };
        t.* = try benchSlice(app, io);
    }
    if (app.job) |*pj| try err.print("tree layers made again: {d} of {d}\n", .{ pj.groups[0].job.support_cache.tree_layers.made, pj.groups[0].job.layers.len });
    try printTimes(err, "tree edit", edits[0..times.len]);
    try printTimes(err, "tree slice", times);
    _ = st.reset(app, 0);
}

/// Each patch setting alone (see settings.patch_settings): the time of the
/// slice after its change, the plans that the slice made, and a
/// comparison of the G-code with the G-code of a new app.
fn benchPatch(gpa: std.mem.Allocator, app: *zslice.app.App, io: Io, err: *Io.Writer, name: []const u8, bytes: []const u8, settings: zslice.Settings) !void {
    var differ: usize = 0;
    for (zslice.app.patch_values) |v| {
        app.settings = settings;
        _ = try benchSlice(app, io);
        try app.setSetting(v[0], v[1]);
        const plans = zslice.plate_job.plans_made.load(.monotonic);
        const t = try benchSlice(app, io);
        const made = zslice.plate_job.plans_made.load(.monotonic) - plans;
        const fresh = try zslice.app.App.create(gpa, null, null);
        defer fresh.destroy();
        fresh.settings = app.settings;
        try fresh.loadStl(std.fs.path.basename(name), bytes);
        _ = try benchSlice(fresh, io);
        const same = std.mem.eql(u8, app.gcode().?, fresh.gcode().?);
        if (!same) differ += 1;
        try err.print("{s:<34} {d:>7.1} ms   plans {d:>4}   {s}\n", .{ v[0], t.wall, made, if (same) "same G-code" else "OTHER G-CODE" });
        try err.flush();
    }
    try err.print("patch settings with other G-code: {d}\n", .{differ});
}

/// The time from a cancel to the end of the slice. A slice of new
/// outlines starts, and after a delay a new value of the layer height
/// cancels it, as in the app.
fn benchCancel(app: *zslice.app.App, io: Io, err: *Io.Writer, settings: zslice.Settings) !void {
    const delays = [_]i64{ 2, 5, 10, 20, 40, 80, 120, 160 };
    var worst: f64 = 0;
    var sum: f64 = 0;
    var n: usize = 0;
    for (0..3) |round| {
        for (delays, 0..) |d, k| {
            app.settings = settings;
            const h = 0.2 + 0.001 * @as(f64, @floatFromInt(round * delays.len + k + 1));
            var buf: [32]u8 = undefined;
            try app.setSetting("project.layer_height", try std.fmt.bufPrint(&buf, "{d:.3}", .{h}));
            try app.requestSlice();
            try io.sleep(.fromMilliseconds(d), .awake);
            const t0 = Io.Clock.awake.now(io);
            app.cancel();
            if (app.worker) |t| {
                t.join();
                app.worker = null;
            }
            const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
            worst = @max(worst, ms);
            sum += ms;
            n += 1;
        }
    }
    try err.print("{s:<14} mean {d:>7.1} ms   worst {d:>7.1} ms\n", .{ "cancel", sum / @as(f64, @floatFromInt(n)), worst });
}

/// An allocator that counts the bytes in use and keeps the peak. It is
/// thread-safe if its backing allocator is.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn add(self: *CountingAllocator, n: usize) void {
        const now = self.live.fetchAdd(n, .monotonic) + n;
        _ = self.peak.fetchMax(now, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, a, ra) orelse return null;
        self.add(len);
        return p;
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(mem, a, new_len, ra)) return false;
        if (new_len > mem.len) self.add(new_len - mem.len) else _ = self.live.fetchSub(mem.len - new_len, .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(mem, a, new_len, ra) orelse return null;
        if (new_len > mem.len) self.add(new_len - mem.len) else _ = self.live.fetchSub(mem.len - new_len, .monotonic);
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(mem, a, ra);
        _ = self.live.fetchSub(mem.len, .monotonic);
    }
};

/// The wall time and the CPU time (all threads) of one slice, in ms, and
/// the page faults.
const Sample = struct { wall: f64, cpu: f64, faults: f64 };

fn cpuNow() [2]f64 {
    const u = std.posix.getrusage(0);
    const ms = @as(f64, @floatFromInt(u.utime.sec + u.stime.sec)) * 1e3 +
        @as(f64, @floatFromInt(u.utime.usec + u.stime.usec)) / 1e3;
    return .{ ms, @floatFromInt(u.minflt) };
}

/// The simulated print of the last slice (App.simulatePrint): its time,
/// the memory it adds at its peak, and its numbers.
fn benchSim(app: *zslice.app.App, io: Io, err: *Io.Writer, counter: *CountingAllocator, times: []Sample) !void {
    var st: zslice.print_sim.Stats = .{};
    var extra: usize = 0;
    for (times) |*t| {
        try app.showSimulated(false);
        const live = counter.live.load(.monotonic);
        counter.peak.store(live, .monotonic);
        const t0 = Io.Clock.awake.now(io);
        const c0 = cpuNow();
        st = try app.simulatePrint();
        const c1 = cpuNow();
        t.* = .{ .wall = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6, .cpu = c1[0] - c0[0], .faults = c1[1] - c0[1] };
        extra = @max(extra, counter.peak.load(.monotonic) - live);
    }
    try printTimes(err, "simulate", times);
    try err.print("simulate: {d} masses, {d} soft, peak {d} soft, {d} moved in {d} paths, max move {d:.2} mm, {d:.2} g, {d} steps, {d:.1} MB more at the peak\n", .{ st.masses, st.soft_masses, st.peak_soft, st.moved, st.moved_paths, st.max_move, st.mass, st.steps, @as(f64, @floatFromInt(extra)) / (1 << 20) });
}

fn addCopies(app: *zslice.app.App, name: []const u8, bytes: []const u8, copies: usize) !void {
    if (copies <= 1) return;
    for (1..copies) |_| _ = try app.addStl(std.fs.path.basename(name), bytes);
    _ = try app.arrangePlate();
}

fn benchSlice(app: *zslice.app.App, io: Io) !Sample {
    const t0 = Io.Clock.awake.now(io);
    const c0 = cpuNow();
    try app.requestSlice();
    if (app.worker) |t| {
        t.join();
        app.worker = null;
    }
    const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
    const c1 = cpuNow();
    if (app.getState() != .done) return error.SliceFailed;
    return .{ .wall = ms, .cpu = c1[0] - c0[0], .faults = c1[1] - c0[1] };
}

fn printTimes(err: *Io.Writer, kind: []const u8, samples: []Sample) !void {
    var wall: [max_runs]f64 = undefined;
    var cpu: [max_runs]f64 = undefined;
    var faults: [max_runs]f64 = undefined;
    for (samples, 0..) |x, i| {
        wall[i] = x.wall;
        cpu[i] = x.cpu;
        faults[i] = x.faults;
    }
    const n = samples.len;
    for ([_][]f64{ wall[0..n], cpu[0..n], faults[0..n] }) |v| std.mem.sort(f64, v, {}, std.sort.asc(f64));
    try err.print("{s:<14} wall median {d:>7.1} min {d:>7.1} ms   cpu median {d:>7.1} ms   faults {d:>7.0}\n", .{ kind, wall[n / 2], wall[0], cpu[n / 2], faults[n / 2] });
    try err.flush();
}

/// Reads a G-code file in pieces of 1 MB, as a printer host does, and
/// prints what the reader finds, its time, and the peak memory.
fn gcodeInfo(gpa: std.mem.Allocator, io: Io, err: *Io.Writer, path: []const u8) !void {
    var counter: CountingAllocator = .{ .backing = gpa };
    const t0 = Io.Clock.awake.now(io);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var r: zslice.gcode_read.Reader = .init(counter.allocator());
    defer r.deinit();
    var fr = file.reader(io, &.{});
    const piece = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(piece);
    while (true) {
        const n = try fr.interface.readSliceShort(piece);
        if (n == 0) break;
        try r.feed(piece[0..n]);
    }
    try r.finish();
    const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
    try err.print("{d} bytes, {d} layers, {d} moves ({d} beads)\n", .{ r.size, r.layers.items.len, r.len, r.bead_count });
    try err.print("box: x {d:.2} to {d:.2}, y {d:.2} to {d:.2}, z {d:.2} to {d:.2} mm\n", .{ r.box[0], r.box[3], r.box[1], r.box[4], r.box[2], r.box[5] });
    try err.print("filament {d:.2} mm, print time {d:.0} s\n", .{ r.filament, r.total_time });
    try err.print("read in {d:.0} ms; peak memory: {d} MB resident (VmHWM), {d} MB allocated\n", .{ ms, peakMb(io), counter.peak.load(.monotonic) >> 20 });
}

/// The peak resident memory of this process, in MB, from /proc.
fn peakMb(io: Io) u64 {
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/self/status", &buf) catch return 0;
    const at = std.mem.indexOf(u8, text, "VmHWM:") orelse return 0;
    var tok = std.mem.tokenizeAny(u8, text[at + 6 ..], " \t\n");
    const kb = std.fmt.parseInt(u64, tok.next() orelse return 0, 10) catch return 0;
    return kb / 1024;
}

fn fail(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print(fmt, args) catch {};
    err.flush() catch {};
    std.process.exit(2);
}

fn parseOptions(arena: std.mem.Allocator, err: *Io.Writer, args: []const [:0]const u8, opts: *Options) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const takes_value = for ([_][]const u8{ "-o", "-s", "--layer", "-m", "--machine", "-f", "--filament", "-p", "--project", "--only", "--runs", "--points", "--copies" }) |o| {
            if (std.mem.eql(u8, a, o)) break true;
        } else false;
        if (!takes_value) {
            if (opts.input != null) fail(err, "unexpected argument: {s}\n", .{a});
            opts.input = a;
            continue;
        }
        if (i + 1 >= args.len) fail(err, "{s} needs a value\n", .{a});
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "-o")) {
            opts.output = v;
        } else if (std.mem.eql(u8, a, "--layer")) {
            opts.layer = std.fmt.parseInt(usize, v, 10) catch fail(err, "bad layer number: {s}\n", .{v});
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--machine")) {
            opts.machine = v;
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--filament")) {
            opts.filament = v;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--project")) {
            opts.project = v;
        } else if (std.mem.eql(u8, a, "--only")) {
            opts.only = v;
        } else if (std.mem.eql(u8, a, "--points")) {
            opts.points = std.fmt.parseInt(usize, v, 10) catch fail(err, "bad point count: {s}\n", .{v});
            if (opts.points < 2 or opts.points > 50) fail(err, "--points must be 2 to 50\n", .{});
        } else if (std.mem.eql(u8, a, "--copies")) {
            opts.copies = std.fmt.parseInt(usize, v, 10) catch fail(err, "bad copy count: {s}\n", .{v});
            if (opts.copies < 1 or opts.copies > 64) fail(err, "--copies must be 1 to 64\n", .{});
        } else if (std.mem.eql(u8, a, "--runs")) {
            opts.runs = std.fmt.parseInt(usize, v, 10) catch fail(err, "bad run count: {s}\n", .{v});
            if (opts.runs < 1 or opts.runs > max_runs) fail(err, "--runs must be 1 to {d}\n", .{max_runs});
        } else {
            try opts.sets.append(arena, v);
        }
    }
}

fn importCura(arena: std.mem.Allocator, io: Io, err: *Io.Writer, stack: []const u8, out_dir: []const u8) !void {
    const Src = struct {
        io: Io,
        dir: []const u8,
        fn read(ctx: ?*anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const full = std.fs.path.join(a, &.{ self.dir, path }) catch return null;
            return Io.Dir.cwd().readFileAlloc(self.io, full, a, .limited(16 << 20)) catch null;
        }
    };
    var src: Src = .{ .io = io, .dir = stack };
    var diag: zslice.import_cura.Diagnostic = .{};
    const outs = zslice.import_cura.importStack(arena, .{ .ctx = &src, .read = Src.read }, &diag) catch |e| {
        fail(err, "{s}: {s} ({s})\n", .{ diag.file, diag.message, @errorName(e) });
    };
    for (outs) |o| {
        const dir = try std.fs.path.join(arena, &.{ out_dir, o.group });
        try Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.toml", .{ dir, o.name });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = o.text });
        try err.print("wrote {s}\n", .{path});
    }
}

/// $XDG_CONFIG_HOME/zslice, or ~/.config/zslice.
fn configDir(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fmt.allocPrint(arena, "{s}/zslice", .{x}) catch null;
    if (env.get("HOME")) |h| return std.fmt.allocPrint(arena, "{s}/.config/zslice", .{h}) catch null;
    return null;
}

/// Finds profile files on disk. See the usage text for the search order.
const FileResolver = struct {
    io: Io,
    config_dir: ?[]const u8,

    fn isPath(name: []const u8) bool {
        return std.mem.indexOfScalar(u8, name, '/') != null or std.mem.endsWith(u8, name, ".toml");
    }

    fn read(self: *FileResolver, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(1 << 20)) catch null;
    }

    fn load(ctx: ?*anyopaque, arena: std.mem.Allocator, group: profile.Group, name: []const u8, from: []const u8) ?[]const u8 {
        const self: *FileResolver = @ptrCast(@alignCast(ctx.?));
        const g = @tagName(group);
        if (isPath(name)) {
            // A relative path in a profile file is relative to that file.
            if (isPath(from) and !std.fs.path.isAbsolute(name)) {
                if (std.fs.path.dirname(from)) |dir| {
                    const p = std.fs.path.join(arena, &.{ dir, name }) catch return null;
                    if (self.read(arena, p)) |t| return t;
                }
            }
            return self.read(arena, name);
        }
        // A name next to the profile file that asks.
        if (isPath(from)) {
            if (std.fs.path.dirname(from)) |dir| {
                const p = std.fmt.allocPrint(arena, "{s}/{s}.toml", .{ dir, name }) catch return null;
                if (self.read(arena, p)) |t| return t;
            }
        }
        const local = std.fmt.allocPrint(arena, "profiles/{s}/{s}.toml", .{ g, name }) catch return null;
        if (self.read(arena, local)) |t| return t;
        if (self.config_dir) |d| {
            const p = std.fmt.allocPrint(arena, "{s}/profiles/{s}/{s}.toml", .{ d, g, name }) catch return null;
            if (self.read(arena, p)) |t| return t;
        }
        if (group == .machine) return libraryProfile(arena, name);
        return null;
    }

    /// The machine profile of the printer with the id `name` in the
    /// printer library, or null. A built-in profile of that name comes
    /// first.
    fn libraryProfile(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
        for (profile.builtins) |b| if (b.group == .machine and std.mem.eql(u8, b.name, name)) return null;
        const lib = zslice.printers.Library.parse(arena, zslice.printers.builtin_data) catch return null;
        defer lib.deinit();
        const i = lib.find(name) orelse return null;
        var out: std.Io.Writer.Allocating = .init(arena);
        lib.profileText(i, 0, &out.writer) catch return null;
        return out.written();
    }
};

/// Calls `func(value, writer)` with a writer to the file at `path`, or to
/// stdout if `path` is null.
fn writeOut(io: Io, path: ?[]const u8, value: anytype, comptime func: anytype) !ReturnPayload(@TypeOf(func)) {
    var buf: [64 * 1024]u8 = undefined;
    if (path) |p| {
        const file = try Io.Dir.cwd().createFile(io, p, .{});
        defer file.close(io);
        var fw: Io.File.Writer = .init(file, io, &buf);
        const result = try func(value, &fw.interface);
        try fw.interface.flush();
        return result;
    }
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    const result = try func(value, &fw.interface);
    try fw.interface.flush();
    return result;
}

fn ReturnPayload(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return @typeInfo(R).error_union.payload;
}

fn listSettings(w: *Io.Writer) !void {
    const defaults: zslice.Settings = .{};
    inline for (@typeInfo(zslice.Settings).@"struct".fields) |g| {
        const group = @field(defaults, g.name);
        inline for (@typeInfo(@TypeOf(group)).@"struct".fields) |f| {
            const v = @field(group, f.name);
            try w.print("{s}.{s} = ", .{ g.name, f.name });
            switch (@typeInfo(f.type)) {
                .float, .int => try w.print("{d}", .{v}),
                .bool => try w.print("{}", .{v}),
                .@"enum" => try w.print("{s}", .{@tagName(v)}),
                .pointer => {
                    try w.writeByte('"');
                    for (v) |c| if (c == '\n') try w.writeAll("\\n") else try w.writeByte(c);
                    try w.writeByte('"');
                },
                else => unreachable,
            }
            try w.writeByte('\n');
        }
    }
}
