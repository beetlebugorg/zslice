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
    \\  zslice import <profile file> [-o <profiles folder>]
    \\  zslice settings
    \\  zslice demo <out.stl>
    \\  zslice bench <model.stl> [options]
    \\  zslice sweep <model.stl> [options] [--points N] [--only TEXT] [-o out.tsv]
    \\  zslice verify [model.stl ...] [--seeds 11,22,33] [--steps 40] [--sweep]
    \\                [--ranges NAME|all] [--restore] [--quick] [-s group.name=value]
    \\  zslice gcode <file.gcode>
    \\
    \\Commands:
    \\  slice     Slice a model and write G-code (default output: stdout).
    \\            A part that does not fit the printer slices with a
    \\            warning; --strict refuses it.
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
    \\            Or convert the profile of another slicer: a PrusaSlicer or
    \\            OrcaSlicer .ini, an OrcaSlicer .json preset, a 3MF project
    \\            of these slicers, or a Cura .curaprofile. The report of
    \\            each value goes to stdout; -o writes the profiles.
    \\  settings  List all settings and their default values.
    \\  gcode     Read a G-code file as the print view does (any slicer):
    \\            print the layers, the moves, the box, the time, the
    \\            time to read it, and the peak memory.
    \\  demo      Write the demo part as an STL file.
    \\  bench     Slice in the app core: once from the start, then again
    \\            after a change of each kind of setting. Print the times
    \\            and the peak memory. --only KIND times one kind: full,
    \\            draft (the slice for the view during a drag),
    \\            late, walls, top, width, height, support, area, tree, xy,
    \\            speed, accel, flow, fan, temp, cool, cancel, paint (the
    \\            lower sixth of the part brushed with a second
    \\            filament), dexel (the skin of each layer
    \\            from line cuts, against polygon booleans), or sim
    \\            (the simulated print of the plastic; sim-side and
    \\            sim-flip turn the part on its side or upside down
    \\            first, for steep overhangs; sim-local changes the
    \\            infill of the upper half of the part, and runs the
    \\            simulation from a checkpoint; -o FILE writes the
    \\            masses that moved as CSV). --only
    \\            patch changes each setting that needs no new plan, and
    \\            compares the G-code with a new slice. --only verify
    \\            makes each change in turn, and compares the G-code of
    \\            each slice with a new slice. --runs N sets
    \\            the slices of each kind (default 6). --only noop slices
    \\            with no change. The edits of the slice form: edit (the
    \\            flow of one line), zrange and zwalls (the infill or the
    \\            walls of z 5 to 10 mm), zfil (a second filament for a
    \\            range), undo (the infill there and back), prefs
    \\            (engine.auto_simulate), move, turnz, move2 (moves the
    \\            model of --second FILE), and draftexact (the exact slice
    \\            after three drafts). Each one compares its G-code with a
    \\            slice from the start. --stages prints, after each kind, the
    \\            time of each stage for one slice and the counts of the
    \\            plans, runs, texts, booleans, and offsets.
    \\  verify    Prove that kept work does not change a slice. Two apps get
    \\            the same edits. One keeps its work, and one slices from
    \\            the start. The G-code, the toolpaths, and the statistics
    \\            must be equal. The exit code is 1 after a fault. --sweep
    \\            tries each value of each setting from three base states.
    \\            --ranges tries overrides of a layer setting on z ranges.
    \\            --restore also loads the 3MF after each eighth step.
    \\            --quick is the sweep of one base state and 3 seeds. With
    \\            no model, the tool uses the demo part.
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
    /// slice: refuse a part that does not fit the printer (else warn).
    strict: bool = false,
    /// bench: print the time of each stage and the counts of the work.
    stages: bool = false,
    /// bench: a second model on the plate (--only move2).
    second: ?[]const u8 = null,
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
        if (args.len == 6 and std.mem.eql(u8, args[2], "cura") and std.mem.eql(u8, args[4], "-o")) {
            try importCura(arena, io, err, args[3], args[5]);
            return;
        }
        if (args.len == 3) {
            try importProfile(arena, io, err, args[2], null);
            return;
        }
        if (args.len == 5 and std.mem.eql(u8, args[3], "-o")) {
            try importProfile(arena, io, err, args[2], args[4]);
            return;
        }
        fail(err, "{s}", .{usage});
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

    if (std.mem.eql(u8, cmd, "verify")) return verifyCommand(arena, gpa, io, err, args[2..]);

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
        try bench(gpa, io, err, in_path, bytes, settings, opts.only, opts.runs, opts.copies, opts.output, opts.stages, opts.second);
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
    // Each part stands on the bed: a plate slices from z 0 (PartInput
    // takes a mesh in the frame of the plate), and a file can have its
    // lowest point at any z (a CAD export at z -80, for example).
    if (loaded) |*l| {
        for (l.parts) |*p| if (p.mesh.faces.items.len > 0) p.mesh.translate(0, 0, -p.mesh.bounds().min[2]);
    }
    if (m.faces.items.len > 0) m.translate(0, 0, -m.bounds().min[2]);
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

    // A part higher than the printer, or wider or deeper than the bed,
    // does not print: the G-code would move off the bed. The CLI slices it
    // with a warning, as the apps do, and refuses it with --strict.
    {
        const b = m.bounds();
        const f = zslice.engine.fitOf(b.min, b.max, settings);
        if (f.cause != .fits) {
            var words: [400]u8 = undefined;
            var w: Io.Writer = .fixed(&words);
            zslice.engine.fitText(f, &w) catch {};
            if (opts.strict) fail(err, "slice failed: PartTooLarge. {s}\n", .{w.buffered()});
            err.print("warning: the part does not fit the printer, and the G-code does not print on it. {s}\n", .{w.buffered()}) catch {};
            err.flush() catch {};
        }
    }

    const t0 = Io.Clock.awake.now(io);
    // One slice: the memos need not stay (see Job.keep_memos).
    // No island search: the G-code does not use the islands.
    var job = zslice.PlateJob.init(gpa, settings, part_inputs.items, .{ .keep_memos = false, .islands = false }) catch |e| fail(err, "slice failed: {s}\n", .{@errorName(e)});
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

/// `zslice verify`: see verify.zig. Exits with 1 after a fault.
fn verifyCommand(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: Io, err: *Io.Writer, args: []const [:0]const u8) !void {
    var opts: zslice.verify.Options = .{ .random = false };
    var models: std.ArrayList(zslice.verify.Model) = .empty;
    var sets: std.ArrayList([]const u8) = .empty;
    var seeds: std.ArrayList(u64) = .empty;
    var quick = false;
    var explicit_random = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = struct {
            fn f(e: *Io.Writer, list: []const [:0]const u8, k: *usize) []const u8 {
                k.* += 1;
                if (k.* >= list.len) fail(e, "{s} needs a value\n", .{list[k.* - 1]});
                return list[k.*];
            }
        }.f;
        if (std.mem.eql(u8, a, "--sweep")) {
            opts.sweep = true;
        } else if (std.mem.eql(u8, a, "--restore")) {
            opts.restore = true;
            explicit_random = true;
        } else if (std.mem.eql(u8, a, "--quick")) {
            quick = true;
        } else if (std.mem.eql(u8, a, "--ranges")) {
            opts.ranges = value(err, args, &i);
        } else if (std.mem.eql(u8, a, "--steps")) {
            const v = value(err, args, &i);
            opts.steps = std.fmt.parseInt(usize, v, 10) catch fail(err, "--steps: {s}\n", .{v});
            explicit_random = true;
        } else if (std.mem.eql(u8, a, "--seeds")) {
            var it = std.mem.tokenizeScalar(u8, value(err, args, &i), ',');
            while (it.next()) |t| try seeds.append(arena, std.fmt.parseInt(u64, t, 10) catch fail(err, "--seeds: {s}\n", .{t}));
            explicit_random = true;
        } else if (std.mem.eql(u8, a, "-s")) {
            try sets.append(arena, value(err, args, &i));
        } else if (a.len > 0 and a[0] == '-') {
            fail(err, "unknown option: {s}\n\n{s}", .{ a, usage });
        } else {
            const bytes = try Io.Dir.cwd().readFileAlloc(io, a, arena, .unlimited);
            try models.append(arena, .{ .name = std.fs.path.basename(a), .bytes = bytes });
        }
    }
    if (models.items.len == 0) {
        var m = try zslice.mesh.shapes.demo(gpa);
        defer m.deinit(gpa);
        var stl: Io.Writer.Allocating = .init(arena);
        try m.writeStl(&stl.writer);
        try models.append(arena, .{ .name = "demo.stl", .bytes = stl.written() });
    }
    if (quick) {
        opts.sweep = true;
        opts.sweep_bases = 1;
        explicit_random = true;
    }
    opts.random = explicit_random or (!opts.sweep and opts.ranges == null);
    if (seeds.items.len > 0) opts.seeds = seeds.items;
    opts.sets = sets.items;
    const r = try zslice.verify.run(gpa, io, models.items, opts, err);
    try err.flush();
    if (r.faults > 0 or (opts.restore and r.restore_faults > 0)) std.process.exit(1);
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
    .{ .key = "3mf", .kind = "3mf write", .name = "", .values = .{ "", "", "", "", "", "" } },
    .{ .key = "xy", .kind = "xy offset", .name = "filament.xy_offset", .values = .{ "0.01", "0.02", "0.03", "0.04", "0.05", "0.06" } },
    // Settings that change no path: the slice runs from the move streams
    // (see settings.patch_settings).
    .{ .key = "speed", .kind = "wall speed", .name = "project.outer_wall_speed", .values = .{ "0.41", "0.42", "0.43", "0.44", "0.45", "0.46" } },
    .{ .key = "accel", .kind = "wall accel", .name = "machine.outer_wall_accel", .values = .{ "810", "820", "830", "840", "850", "860" } },
    .{ .key = "flow", .kind = "flow ratio", .name = "filament.flow_ratio", .values = .{ "0.95", "0.96", "0.97", "0.98", "0.99", "1.01" } },
    .{ .key = "fan", .kind = "fan speed", .name = "filament.fan_speed", .values = .{ "0.81", "0.82", "0.83", "0.84", "0.85", "0.86" } },
    .{ .key = "temp", .kind = "nozzle temp", .name = "filament.nozzle_temp", .values = .{ "211", "212", "213", "214", "215", "216" } },
    .{ .key = "cool", .kind = "layer time", .name = "filament.min_layer_time", .values = .{ "7", "8", "9", "10", "11", "12" } },
};

/// The edits of the gate tables of the slice form (see benchEdit).
const edit_kinds = [_][]const u8{ "edit", "zrange", "zwalls", "zfil", "undo", "prefs", "move", "turnz", "move2", "draftexact" };

/// One kind of edit of `edit_kinds`, with a new value for each slice. Each
/// slice is timed. At the end, the app drops its work and slices again,
/// and the two G-codes must be equal ("same").
fn benchEdit(gpa: std.mem.Allocator, app: *zslice.app.App, io: Io, err: *Io.Writer, settings: zslice.Settings, kind: []const u8, times: []Sample, stages: bool, second: ?[]const u8) !void {
    const clock = zslice.stage_clock;
    const eq = std.mem.eql;
    var buf: [64]u8 = undefined;
    app.settings = settings;
    if (eq(u8, kind, "move2")) {
        const path = second orelse fail(err, "--only move2 needs --second <model>\n", .{});
        const b2 = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(b2);
        _ = try app.addStl(std.fs.path.basename(path), b2);
        _ = try app.arrangePlate();
    }
    if (eq(u8, kind, "zfil")) {
        _ = try zslice.app.filament_slots.add(app);
        try app.setOverride(5, 10, "project.filament", "2");
    }
    if (eq(u8, kind, "zrange")) try app.setOverride(5, 10, "project.infill_density", "0.3");
    if (eq(u8, kind, "zwalls")) try app.setOverride(5, 10, "project.wall_count", "2");
    _ = try benchSlice(app, io);
    // The line of a flow edit: a path in the middle level.
    var edit_key: u64 = 0;
    var edit_level: u32 = 0;
    if (eq(u8, kind, "edit")) {
        const tp = &app.toolpaths;
        edit_level = @intCast(tp.layer_ends.items.len / 2);
        const p0 = tp.layer_ends.items[edit_level - 1];
        if (p0 + 3 >= tp.path_key.items.len) return error.SliceFailed;
        edit_key = tp.path_key.items[p0 + 3];
    }
    const last = app.plate.count() - 1;
    const x0 = app.plate.parts.items[0].x;
    const y0 = app.plate.parts.items[0].y;
    clock.reset();
    for (times, 0..) |*t, k| {
        const kf: f64 = @floatFromInt(k + 1);
        if (eq(u8, kind, "edit")) {
            try app.edits.put(gpa, .{ .key = edit_key, .kind = .flow, .value = @floatCast(0.5 + 0.05 * kf), .layer = edit_level });
        } else if (eq(u8, kind, "zrange")) {
            try app.setOverride(5, 10, "project.infill_density", try std.fmt.bufPrint(&buf, "{d:.2}", .{0.3 + 0.01 * kf}));
        } else if (eq(u8, kind, "zwalls")) {
            try app.setOverride(5, 10, "project.wall_count", try std.fmt.bufPrint(&buf, "{d}", .{3 + k % 4}));
        } else if (eq(u8, kind, "zfil")) {
            // The top of the range moves up by 0.2 mm on each slice.
            for (app.overrides.items) |*o| if (eq(u8, o.name, "project.filament")) {
                o.z_max = 10 + 0.2 * kf;
            };
        } else if (eq(u8, kind, "undo")) {
            try app.setSetting("project.infill_density", if (k % 2 == 0) "0.3" else "0.2");
        } else if (eq(u8, kind, "prefs")) {
            try app.setSetting("engine.auto_simulate", if (k % 2 == 0) "false" else "true");
        } else if (eq(u8, kind, "move")) {
            try app.movePart(0, x0 + 1.234 * kf, y0 + 0.5 * kf);
        } else if (eq(u8, kind, "turnz")) {
            try app.rotatePart(0, 15 * kf);
        } else if (eq(u8, kind, "move2")) {
            try app.movePart(last, app.plate.parts.items[last].x + 0.777, app.plate.parts.items[last].y);
        } else if (eq(u8, kind, "draftexact")) {
            // A drag with a live view: three drafts of the infill, then
            // the exact slice. Only the exact slice is timed.
            clock.pause();
            app.setDraft(true);
            for (0..3) |d| {
                try app.setSetting("project.infill_density", try std.fmt.bufPrint(&buf, "{d:.3}", .{0.2 + 0.01 * kf + 0.001 * @as(f64, @floatFromInt(d))}));
                _ = try benchSlice(app, io);
            }
            app.setDraft(false);
            clock.unpause();
        }
        t.* = try benchSlice(app, io);
    }
    try printTimes(err, kind, times);
    if (stages) try clock.print(err, @floatFromInt(times.len));
    // The twin: the same state, sliced from the start.
    clock.pause();
    defer clock.unpause();
    const kept = try gpa.dupe(u8, app.gcode() orelse "");
    defer gpa.free(kept);
    app.dropWork();
    _ = try benchSlice(app, io);
    try err.print("  G-code against a slice from the start: {s}\n", .{if (eq(u8, kept, app.gcode() orelse "")) "same" else "OTHER"});
}

/// The most slices of one kind in a bench.
const max_runs = 64;

/// Slices in the app core, as the app does after each change of a setting,
/// and prints the time of each slice and the peak memory (VmHWM).
fn bench(backing: std.mem.Allocator, io: Io, err: *Io.Writer, name: []const u8, bytes: []const u8, settings: zslice.Settings, only: ?[]const u8, runs: usize, copies: usize, out: ?[]const u8, stages: bool, second: ?[]const u8) !void {
    const App = zslice.app.App;
    const clock = zslice.stage_clock;
    clock.on.store(stages, .monotonic);
    defer clock.on.store(false, .monotonic);
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
        const sl = try benchSlice(app, io);
        try err.print("slice: {d:.1} ms wall, {d:.1} ms cpu\n", .{ sl.wall, sl.cpu });
        if (std.mem.eql(u8, only.?, "sim-local")) return benchSimLocal(app, io, err, times);
        try benchSim(app, io, err, &counter, times);
        if (out) |path| try writeSimMasses(app, io, path);
        try err.print("peak memory: {d} MB resident (VmHWM), {d} MB allocated\n", .{ peakMb(io), counter.peak.load(.monotonic) >> 20 });
        return;
    }
    if (only != null and std.mem.eql(u8, only.?, "dexel")) return benchDexel(gpa, io, err, bytes, settings, runs);
    if (only != null and std.mem.eql(u8, only.?, "paint")) {
        for (times, 0..) |*t, k| {
            // A new model drops the split of the slice before.
            try app.loadStl(std.fs.path.basename(name), bytes);
            try benchPaint(gpa, app, if (k == 0) err else null);
            t.* = try benchSlice(app, io);
        }
        try printTimes(err, "paint split", times);
        if (app.result()) |st| try err.print("filament: {d:.3} g of the part, {d:.3} g of the paint, {d} changes\n", .{ st.slot_g[0], st.slot_g[1], st.changes });
        try err.print("peak memory: {d} MB resident (VmHWM), {d} MB allocated\n", .{ peakMb(io), counter.peak.load(.monotonic) >> 20 });
        return;
    }
    if (only != null and std.mem.eql(u8, only.?, "draft")) {
        // The draft slice of a drag (App.setDraft), each one from the
        // start.
        app.setDraft(true);
        for (times) |*t| {
            try app.loadStl(std.fs.path.basename(name), bytes);
            try addCopies(app, name, bytes, copies);
            t.* = try benchSlice(app, io);
        }
        try printTimes(err, "draft slice", times);
        return;
    }
    if (only == null or std.mem.eql(u8, only.?, "full")) {
        // The first slice has no cache. Each one starts new.
        clock.reset();
        for (times) |*t| {
            // A new model drops the regions of the slice before.
            try app.loadStl(std.fs.path.basename(name), bytes);
            try addCopies(app, name, bytes, copies);
            t.* = try benchSlice(app, io);
        }
        try printTimes(err, "full slice", times);
        if (stages) try clock.print(err, @floatFromInt(times.len));
    } else {
        try app.loadStl(std.fs.path.basename(name), bytes);
        try addCopies(app, name, bytes, copies);
    }
    if (only) |o| for (edit_kinds) |k| if (std.mem.eql(u8, o, k)) {
        try benchEdit(gpa, app, io, err, settings, o, times, stages, second);
        try err.print("peak memory: {d} MB resident (VmHWM), {d} MB allocated\n", .{ peakMb(io), counter.peak.load(.monotonic) >> 20 });
        return;
    };
    if (only != null and std.mem.eql(u8, only.?, "noop")) {
        // A slice with no change.
        app.settings = settings;
        _ = try benchSlice(app, io);
        clock.reset();
        for (times) |*t| t.* = try benchSlice(app, io);
        try printTimes(err, "no change", times);
        if (stages) try clock.print(err, @floatFromInt(times.len));
    }
    for (bench_changes) |c| {
        if (only) |o| if (!std.mem.eql(u8, o, c.key)) continue;
        // Start from the base settings, with a slice that is not timed.
        app.settings = settings;
        _ = try benchSlice(app, io);
        clock.reset();
        if (std.mem.eql(u8, c.key, "tree")) {
            try benchTree(app, io, err, times);
            if (stages) try clock.print(err, @floatFromInt(times.len));
            clock.unpause();
            continue;
        }
        if (std.mem.eql(u8, c.key, "3mf")) {
            // The 3MF of the plate, as a history step writes it after a move.
            for (times, 0..) |*t, k| {
                app.plate.parts.items[0].x += 0.1 * @as(f64, @floatFromInt(k + 1));
                const t0 = Io.Clock.awake.now(io);
                const f = try app.write3mfAlloc(gpa);
                gpa.free(f);
                const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
                t.* = .{ .wall = ms, .cpu = ms, .faults = 0 };
            }
            try printTimes(err, "3mf write", times);
            for (times, 0..) |*t, k| {
                app.plate.parts.items[0].x += 0.1 * @as(f64, @floatFromInt(k + 1));
                const t0 = Io.Clock.awake.now(io);
                const f = try app.writeSnapshotAlloc(gpa);
                gpa.free(f);
                const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
                t.* = .{ .wall = ms, .cpu = ms, .faults = 0 };
            }
            try printTimes(err, "snapshot write", times);
            {
                const f = try app.writeSnapshotAlloc(gpa);
                defer gpa.free(f);
                try err.print("snapshot size: {d} kB\n", .{f.len / 1024});
            }
            continue;
        }
        if (c.name.len == 0) {
            // A tree area over all of the bed, from z 1 to z 4 (and a
            // little more on each slice).
            const pts = [_][3]f64{ .{ -1000, -1000, 1 }, .{ 2000, -1000, 1 }, .{ 2000, 2000, 1 }, .{ -1000, 2000, 1 } };
            const idx = try app.areas.add(gpa, .tree, &pts, 1, 4);
            _ = try benchSlice(app, io);
            clock.reset();
            for (times, 0..) |*t, k| {
                try app.areas.set(gpa, idx, &pts, 1, 4 + 0.2 * @as(f64, @floatFromInt(k % 6 + 1)));
                t.* = try benchSlice(app, io);
            }
            try app.areas.remove(gpa, idx);
            try printTimes(err, c.kind, times);
            if (stages) try clock.print(err, @floatFromInt(times.len));
            continue;
        }
        for (times, 0..) |*t, k| {
            // The values repeat after 6 slices. Go back to the base
            // settings between the rounds, so that each slice has a new
            // value.
            if (k > 0 and k % c.values.len == 0) {
                app.settings = settings;
                clock.pause();
                _ = try benchSlice(app, io);
                clock.unpause();
            }
            try app.setSetting(c.name, c.values[k % c.values.len]);
            t.* = try benchSlice(app, io);
        }
        try printTimes(err, c.kind, times);
        if (stages) try clock.print(err, @floatFromInt(times.len));
    }
    if (only != null and std.mem.eql(u8, only.?, "patch")) try benchPatch(gpa, app, io, err, name, bytes, settings);
    if (only != null and std.mem.eql(u8, only.?, "verify")) try benchVerify(gpa, app, io, err, name, bytes, settings, copies);
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
        const plans = zslice.plate_job.plans_made.load(.monotonic);
        t.* = try benchSlice(app, io);
        if (i + 1 == times.len) try err.print("tree slice: {d} layer plans\n", .{zslice.plate_job.plans_made.load(.monotonic) - plans});
    }
    // The slices of the checks below stay out of the table of the stages.
    zslice.stage_clock.pause();
    if (app.job) |*pj| try err.print("tree layers made again: {d} of {d}\n", .{ pj.groups[0].job.support_cache.tree_layers.made, pj.groups[0].job.layers.len });
    // The G-code after the edits against a new app with the same trees
    // (from the 3MF of the plate).
    {
        const gpa = app.gpa;
        const file = try app.write3mfAlloc(gpa);
        defer gpa.free(file);
        const fresh = try zslice.app.App.create(gpa, null, null);
        defer fresh.destroy();
        fresh.settings = app.settings;
        try fresh.loadStl("tree.3mf", file);
        _ = try benchSlice(fresh, io);
        const same = std.mem.eql(u8, app.gcode().?, fresh.gcode().?);
        try err.print("tree G-code against a new slice: {s}\n", .{if (same) "same" else "OTHER"});
        // The islands (found again only over the support that changed).
        const a = app.job.?.groups[0].job.islands;
        const b = fresh.job.?.groups[0].job.islands;
        var same_islands = a.len == b.len;
        if (same_islands) for (a, b) |x, y| {
            if (x.layer != y.layer or x.x != y.x or x.y != y.y or x.area != y.area) same_islands = false;
        };
        try err.print("tree islands against a new slice: {s} ({d})\n", .{ if (same_islands) "same" else "OTHER", a.len });
        // The same app sliced again with no job before (no streams): the
        // G-code of the streams against the G-code of new plans.
        const kept = try gpa.dupe(u8, app.gcode().?);
        defer gpa.free(kept);
        if (app.job) |*pj| pj.dropForms();
        _ = try benchSlice(app, io);
        try err.print("tree G-code against new plans in the same app: {s}\n", .{if (std.mem.eql(u8, kept, app.gcode().?)) "same" else "OTHER"});
    }
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

/// Each change of `bench_changes` with a setting, one after the other in
/// the same app (a slice after each), and the G-code of each slice
/// against the G-code of a new app with the same settings.
fn benchVerify(gpa: std.mem.Allocator, app: *zslice.app.App, io: Io, err: *Io.Writer, name: []const u8, bytes: []const u8, settings: zslice.Settings, copies: usize) !void {
    var differ: usize = 0;
    app.settings = settings;
    _ = try benchSlice(app, io);
    for (bench_changes) |c| {
        if (c.name.len == 0) continue;
        for ([_][]const u8{ c.values[1], c.values[0] }) |v| {
            try app.setSetting(c.name, v);
            _ = try benchSlice(app, io);
            const fresh = try zslice.app.App.create(gpa, null, null);
            defer fresh.destroy();
            fresh.settings = app.settings;
            try fresh.loadStl(std.fs.path.basename(name), bytes);
            try addCopies(fresh, name, bytes, copies);
            _ = try benchSlice(fresh, io);
            const same = std.mem.eql(u8, app.gcode().?, fresh.gcode().?);
            if (!same) differ += 1;
            try err.print("{s:<30} {s:<6} {s}\n", .{ c.name, v, if (same) "same G-code" else "OTHER G-CODE" });
            try err.flush();
        }
    }
    try err.print("changes with other G-code: {d}\n", .{differ});
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

/// The calls of cpuNow on Windows, which has no getrusage.
const win_process = struct {
    const FileTime = extern struct {
        low: u32,
        high: u32,

        fn ticks(t: FileTime) u64 {
            return @as(u64, t.high) << 32 | t.low;
        }
    };

    /// PROCESS_MEMORY_COUNTERS.
    const Counters = extern struct {
        cb: u32,
        page_faults: u32,
        sizes: [8]usize,
    };

    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcessTimes(
        process: ?*anyopaque,
        creation: *FileTime,
        exit: *FileTime,
        kernel: *FileTime,
        user: *FileTime,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn K32GetProcessMemoryInfo(
        process: ?*anyopaque,
        counters: *Counters,
        size: u32,
    ) callconv(.winapi) c_int;

    /// A FILETIME counts units of 100 ns.
    fn now() [2]f64 {
        const process = GetCurrentProcess();
        var creation: FileTime = undefined;
        var exit: FileTime = undefined;
        var kernel: FileTime = .{ .low = 0, .high = 0 };
        var user: FileTime = .{ .low = 0, .high = 0 };
        _ = GetProcessTimes(process, &creation, &exit, &kernel, &user);
        return .{ @as(f64, @floatFromInt(kernel.ticks() + user.ticks())) / 1e4, @floatFromInt(memory().page_faults) };
    }

    fn memory() Counters {
        var counters = std.mem.zeroes(Counters);
        counters.cb = @sizeOf(Counters);
        _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, @sizeOf(Counters));
        return counters;
    }

    /// The first size is PeakWorkingSetSize.
    fn peakMb() u64 {
        return memory().sizes[0] >> 20;
    }
};

fn cpuNow() [2]f64 {
    if (@import("builtin").os.tag == .windows) return win_process.now();
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
        // Each run from the start (see benchSimLocal).
        app.dropSimCheckpoints();
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

/// The simulated print after a change of the upper half of the part (an
/// override of the infill density): the simulation runs from the last
/// checkpoint before the change. Prints its times, and checks the result
/// against a simulation from the start.
fn benchSimLocal(app: *zslice.app.App, io: Io, err: *Io.Writer, times: []Sample) !void {
    const zs_ = app.toolpaths.layer_z.items;
    const top: f64 = zs_[zs_.len - 1];
    const z0 = 0.5 * top;
    _ = try app.simulatePrint();
    const values = [_][]const u8{ "0.21", "0.22", "0.23", "0.24", "0.25", "0.26", "0.27", "0.28" };
    var first: usize = 0;
    var paths: usize = 0;
    for (times, 0..) |*t, i| {
        try app.setOverride(z0, top + 1, "project.infill_density", values[i % values.len]);
        _ = try benchSlice(app, io);
        const t0 = Io.Clock.awake.now(io);
        const c0 = cpuNow();
        _ = try app.simulatePrint();
        const c1 = cpuNow();
        t.* = .{ .wall = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6, .cpu = c1[0] - c0[0], .faults = c1[1] - c0[1] };
        first = app.sim_first_path;
        paths = app.toolpaths.pathCount();
    }
    try printTimes(err, "simulate from a checkpoint", times);
    try err.print("override of z {d:.1} to {d:.1}: the last run starts at path {d} of {d}\n", .{ z0, top, first, paths });
    // The same slice, from the start.
    const r = app.sim orelse return error.NoResult;
    const masses = try app.gpa.dupe(zslice.app.sim_print.Mass, r.masses);
    defer app.gpa.free(masses);
    const stats = r.stats;
    const drop = try app.gpa.dupe(f32, r.drop);
    defer app.gpa.free(drop);
    const failed = try app.gpa.dupe(u32, r.failed);
    defer app.gpa.free(failed);
    app.dropSimCheckpoints();
    const t0 = Io.Clock.awake.now(io);
    _ = try app.simulatePrint();
    const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
    const f = app.sim.?;
    const same = std.mem.eql(u8, std.mem.sliceAsBytes(masses), std.mem.sliceAsBytes(f.masses)) and std.meta.eql(stats, f.stats) and
        std.mem.eql(u8, std.mem.sliceAsBytes(drop), std.mem.sliceAsBytes(f.drop)) and std.mem.eql(u32, failed, f.failed);
    try err.print("simulate from the start: {d:.1} ms; same masses: {s}\n", .{ ms, if (same) "yes" else "NO" });
    if (app.sim_checkpoints) |c| try err.print("checkpoints: {d}, {d:.1} MB\n", .{ c.count(), @as(f64, @floatFromInt(c.bytes)) / (1 << 20) });
}

/// Writes the masses of the simulated print that moved as CSV: the part
/// box on the bed, then a row for each mass with its layer, its path, its
/// feature, the place where the slicer meant it to be, and the place where
/// it set.
fn writeSimMasses(app: *zslice.app.App, io: Io, path: []const u8) !void {
    const r = app.sim orelse return error.NoResult;
    const tp = &app.toolpaths;
    var aw: Io.Writer.Allocating = .init(app.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const b = app.partBounds() orelse return error.NoResult;
    try w.print("# part box {d:.3} {d:.3} {d:.3} {d:.3}\n", .{ b[0], b[1], b[2], b[3] });
    try w.print("layer,path,feature,wx,wy,wz,x,y,z\n", .{});
    var layer: usize = 0;
    for (r.masses) |m| {
        while (tp.layer_ends.items[layer] <= m.path) layer += 1;
        const f: zslice.settings.Feature = @enumFromInt(tp.path_features.items[m.path]);
        try w.print("{d},{d},{s},{d:.3},{d:.3},{d:.3},{d:.5},{d:.5},{d:.5}\n", .{ layer, m.path, @tagName(f), m.want[0], m.want[1], m.want[2], m.pos[0], m.pos[1], m.pos[2] });
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

fn addCopies(app: *zslice.app.App, name: []const u8, bytes: []const u8, copies: usize) !void {
    if (copies <= 1) return;
    for (1..copies) |_| _ = try app.addStl(std.fs.path.basename(name), bytes);
    _ = try app.arrangePlate();
}

/// The skin of each layer of a part (the outline minus the area that is
/// in all the layers within the top and bottom thickness), two ways: with
/// the line cuts of dexel.zig, and with polygon booleans. Prints the time
/// of each on one thread, and the skin area of each.
fn benchDexel(gpa: std.mem.Allocator, io: Io, err: *Io.Writer, bytes: []const u8, settings: zslice.Settings, runs: usize) !void {
    const dexel = zslice.dexel;
    const clip = zslice.clip;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var m = try zslice.mesh.Mesh.fromStl(gpa, bytes);
    defer m.deinit(gpa);
    const b = m.bounds();
    const h = settings.project.layer_height;
    const n: usize = @intFromFloat(@floor((b.max[2] - b.min[2]) / h + 1e-9));
    const faces = try a.alloc(u32, m.faces.items.len);
    for (faces, 0..) |*f, i| f.* = @intCast(i);
    const outlines = try a.alloc(zslice.geom.Paths, n);
    var points: usize = 0;
    for (outlines, 0..) |*o, i| {
        o.* = try zslice.slicer.sliceAt(a, &m, faces, b.min[2] + (@as(f64, @floatFromInt(i)) + 0.5) * h, 0, 0);
        points += o.points.items.len;
    }
    const pitch: f64 = @floatFromInt(zslice.geom.fromMm(if (settings.project.line_width > 0) settings.project.line_width else 0.45));
    const top: usize = @intFromFloat(@round(settings.project.top_thickness / h));
    const bottom: usize = @intFromFloat(@round(settings.project.bottom_thickness / h));
    try err.print("{d} layers, {d} outline points, {d} layers of top and {d} of bottom, lines {d:.2} mm apart\n", .{ n, points, top, bottom, pitch / 1000 });

    var best_cut: f64 = std.math.inf(f64);
    var best_skin: f64 = std.math.inf(f64);
    var best_poly: f64 = std.math.inf(f64);
    var line_area: f64 = 0;
    var poly_area: f64 = 0;
    var intervals: usize = 0;
    for (0..runs) |_| {
        var run_state: std.heap.ArenaAllocator = .init(gpa);
        defer run_state.deinit();
        const ra = run_state.allocator();
        // The two cuts of each layer: the lines at 45 and at 135 degrees.
        const t0 = Io.Clock.awake.now(io);
        const cuts = try ra.alloc([2]dexel.Lines, n);
        for (cuts, outlines) |*c, o| {
            c[0] = try dexel.cut(ra, o, std.math.pi / 4.0, pitch);
            c[1] = try dexel.cut(ra, o, 3.0 * std.math.pi / 4.0, pitch);
        }
        const t1 = Io.Clock.awake.now(io);
        // The skin lines of each layer, in its own direction.
        line_area = 0;
        intervals = 0;
        for (0..n) |i| {
            const d = i % 2;
            var skin: dexel.Lines = .{};
            if (i < bottom or i + top >= n) {
                // A layer near the bottom or the top of the part: all skin.
                skin = cuts[i][d];
            } else {
                var core = cuts[i][d];
                for (i - bottom..i + top + 1) |j| {
                    if (j != i) core = try dexel.boolean(ra, core, cuts[j][d], .intersection);
                }
                skin = try dexel.boolean(ra, cuts[i][d], core, .difference);
            }
            line_area += skin.length() * pitch;
            intervals += skin.u.len / 2;
        }
        const t2 = Io.Clock.awake.now(io);
        best_cut = @min(best_cut, @as(f64, @floatFromInt(t0.durationTo(t1).toNanoseconds())) / 1e6);
        best_skin = @min(best_skin, @as(f64, @floatFromInt(t1.durationTo(t2).toNanoseconds())) / 1e6);
        // The same skin with polygon booleans.
        poly_area = 0;
        for (0..n) |i| {
            if (i < bottom or i + top >= n) {
                poly_area += outlines[i].areaMm2();
                continue;
            }
            var core = outlines[i];
            for (i - bottom..i + top + 1) |j| {
                if (j != i) core = try clip.intersect(ra, core, outlines[j]);
            }
            poly_area += (try clip.difference(ra, outlines[i], core)).areaMm2();
        }
        const t3 = Io.Clock.awake.now(io);
        best_poly = @min(best_poly, @as(f64, @floatFromInt(t2.durationTo(t3).toNanoseconds())) / 1e6);
    }
    try err.print("line cuts:  cut {d:.2} ms, skin {d:.2} ms, {d} skin lines, skin area {d:.1} mm2\n", .{ best_cut, best_skin, intervals, line_area / 1e6 });
    try err.print("polygons:   skin {d:.2} ms, skin area {d:.1} mm2\n", .{ best_poly, poly_area });
}

/// Paints the lower sixth of part 0 with filament 2, as strokes of a
/// brush of 3 mm: a sphere at every 40th vertex there. The edge of the
/// paint has split triangles, as the edge of a brushed area has.
fn benchPaint(gpa: std.mem.Allocator, app: *zslice.app.App, err: ?*Io.Writer) !void {
    if (zslice.app.filament_slots.count(app) < 2) _ = try zslice.app.filament_slots.add(app);
    const part = &app.plate.parts.items[0];
    const m = &part.mesh;
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    for (m.vertices.items) |v| {
        lo = @min(lo, v.z);
        hi = @max(hi, v.z);
    }
    const top = lo + (hi - lo) * 0.16;
    var grid = try zslice.paint.Grid.init(gpa, m);
    defer grid.deinit(gpa);
    const Ctx = struct {
        gpa: std.mem.Allocator,
        list: std.ArrayList(u32) = .empty,
        fn add(cx: *@This(), t: u32) void {
            cx.list.append(cx.gpa, t) catch {};
        }
    };
    var ctx: Ctx = .{ .gpa = gpa };
    defer ctx.list.deinit(gpa);
    var i: usize = 0;
    while (i < m.vertices.items.len) : (i += 40) {
        const v = m.vertices.items[i];
        if (v.z > top) continue;
        ctx.list.clearRetainingCapacity();
        const c: zslice.paint.V3 = .{ v.x, v.y, v.z };
        grid.near(c, 3, &ctx, Ctx.add);
        const sphere: zslice.paint.Sphere = .{ .c = c, .r = 3 };
        for (ctx.list.items) |t| _ = try zslice.paint.brushTriangle(&part.paint, gpa, m, t, sphere, 2, 0.3);
    }
    var painted: usize = 0;
    for (part.paint.states.items) |st| painted += @intFromBool(st != 0);
    if (err) |e| try e.print("paint: {d} of {d} triangles, {d} of them in pieces\n", .{ painted, m.faces.items.len, part.paint.trees.count() });
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
    if (@import("builtin").os.tag == .windows) return win_process.peakMb();
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
        if (std.mem.eql(u8, a, "--strict")) {
            opts.strict = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--stages")) {
            opts.stages = true;
            continue;
        }
        const takes_value = for ([_][]const u8{ "-o", "-s", "--layer", "-m", "--machine", "-f", "--filament", "-p", "--project", "--only", "--runs", "--points", "--copies", "--second" }) |o| {
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
        } else if (std.mem.eql(u8, a, "--second")) {
            opts.second = v;
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

fn importProfile(arena: std.mem.Allocator, io: Io, err: *Io.Writer, path: []const u8, out_dir: ?[]const u8) !void {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20)) catch |e| fail(err, "{s}: {s}\n", .{ path, @errorName(e) });
    const base: zslice.Settings = .{};
    const r = zslice.import_profile.read(arena, bytes, std.fs.path.basename(path), &base) catch |e| switch (e) {
        error.NotProfile => fail(err, "{s}: not a profile of PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura\n", .{path}),
        else => return e,
    };
    var buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &buf);
    try r.writeReport(&out_w.interface);
    try out_w.interface.flush();
    const dir = out_dir orelse return;
    var s = base;
    for (r.changes) |ch| try s.set(ch.name, ch.value);
    const stem = std.fs.path.stem(path);
    for ([_]profile.Group{ .machine, .filament, .project }) |g| {
        var any = false;
        for (r.changes) |ch| {
            if (std.mem.startsWith(u8, ch.name, @tagName(g)) and ch.name[@tagName(g).len] == '.') any = true;
        }
        if (!any) continue;
        var aw: Io.Writer.Allocating = .init(arena);
        try profile.writeChanged(s, g, &aw.writer);
        const gdir = try std.fs.path.join(arena, &.{ dir, @tagName(g) });
        try Io.Dir.cwd().createDirPath(io, gdir);
        const file = try std.fmt.allocPrint(arena, "{s}/{s}.toml", .{ gdir, stem });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = aw.written() });
        try err.print("wrote {s}\n", .{file});
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
            if (comptime f.type == [zslice.settings.max_nozzles]zslice.settings.Nozzle) {
                // The settings of each nozzle after the first, once, with
                // k for the nozzle (1 to 15).
                inline for (@typeInfo(zslice.settings.Nozzle).@"struct".fields) |nf| {
                    try w.print("{s}.{s}.k.{s} = {d}\n", .{ g.name, f.name, nf.name, @field(@field(group, f.name)[1], nf.name) });
                }
                continue;
            }
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
