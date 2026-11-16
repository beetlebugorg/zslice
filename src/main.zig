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
    \\  zslice slice <model.stl> [options] [-o out.gcode]
    \\  zslice preview <model.stl> --layer N [options] [-o out.svg]
    \\  zslice profiles
    \\  zslice profile <machine|filament|project> [options]
    \\  zslice import cura <stack folder> -o <profiles folder>
    \\  zslice settings
    \\  zslice demo <out.stl>
    \\  zslice bench <model.stl> [options]
    \\
    \\Commands:
    \\  slice     Slice a model and write G-code (default output: stdout).
    \\  preview   Write an SVG picture of one layer.
    \\  profiles  List the built-in profiles and where profile files go.
    \\  profile   Write the settings of one group as a profile file, with
    \\            the options applied. Start a new profile from this output.
    \\  import    Convert a Cura profile stack (a folder with cura.json, as in
    \\            the printdeck profiles) to zslice profiles. The output folder
    \\            gets machine/, filament/, and project/ files.
    \\  settings  List all settings and their default values.
    \\  demo      Write the demo part as an STL file.
    \\  bench     Slice in the app core: once from the start, then again
    \\            after a change of each kind of setting. Print the times
    \\            and the peak memory.
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
        try w.writeAll("  the built-in profiles\n\nA path with a / or a .toml name also works: -f ./my-pla.toml\n");
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "import")) {
        if (args.len != 6 or !std.mem.eql(u8, args[2], "cura") or !std.mem.eql(u8, args[4], "-o")) fail(err, "{s}", .{usage});
        try importCura(arena, io, err, args[3], args[5]);
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
    if (!is_bench and !std.mem.eql(u8, cmd, "slice") and !std.mem.eql(u8, cmd, "preview") and !is_profile) {
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
    if (is_bench) {
        defer gpa.free(bytes);
        try bench(gpa, io, err, in_path, bytes, settings);
        return;
    }
    var m = zslice.Mesh.fromStl(gpa, bytes) catch |e| {
        gpa.free(bytes);
        fail(err, "{s}: {s}\n", .{ in_path, @errorName(e) });
    };
    // The mesh has its own copy of the data, so the file buffer can go now.
    gpa.free(bytes);
    defer m.deinit(gpa);

    const t0 = Io.Clock.awake.now(io);
    var job = zslice.engine.Job.init(gpa, &m, settings) catch |e| fail(err, "slice failed: {s}\n", .{@errorName(e)});
    defer job.deinit();
    const pass1 = t0.untilNow(io, .awake);

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
        fn f(j: *zslice.engine.Job, w: *Io.Writer) !zslice.Stats {
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

/// The changes that `bench` makes, one for each kind of setting. Each slice
/// gets a new value, as when a user moves a slider.
const bench_changes = [_]struct { kind: []const u8, name: []const u8, values: [6][]const u8 }{
    .{ .kind = "late (infill)", .name = "project.infill_density", .values = .{ "0.21", "0.22", "0.23", "0.24", "0.25", "0.26" } },
    .{ .kind = "wall count", .name = "project.wall_count", .values = .{ "3", "4", "5", "6", "7", "8" } },
    .{ .kind = "top thickness", .name = "project.top_thickness", .values = .{ "1.0", "1.2", "1.4", "1.6", "1.8", "2.0" } },
    .{ .kind = "line width", .name = "project.line_width", .values = .{ "0.45", "0.46", "0.47", "0.48", "0.49", "0.5" } },
    .{ .kind = "layer height", .name = "project.layer_height", .values = .{ "0.21", "0.22", "0.23", "0.24", "0.25", "0.26" } },
    .{ .kind = "xy offset", .name = "filament.xy_offset", .values = .{ "0.01", "0.02", "0.03", "0.04", "0.05", "0.06" } },
};

/// Slices in the app core, as the app does after each change of a setting,
/// and prints the time of each slice and the peak memory (VmHWM).
fn bench(backing: std.mem.Allocator, io: Io, err: *Io.Writer, name: []const u8, bytes: []const u8, settings: zslice.Settings) !void {
    const App = zslice.app.App;
    var counter: CountingAllocator = .{ .backing = backing };
    const gpa = counter.allocator();
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    app.settings = settings;
    const runs = 6;
    var times: [runs]Sample = undefined;
    // The first slice has no cache. Each one starts new.
    for (&times) |*t| {
        // A new model drops the regions of the slice before.
        try app.loadStl(std.fs.path.basename(name), bytes);
        t.* = try benchSlice(app, io);
    }
    try printTimes(err, "full slice", &times);
    for (bench_changes) |c| {
        // Start from the base settings, with a slice that is not timed.
        app.settings = settings;
        _ = try benchSlice(app, io);
        for (&times, 0..) |*t, k| {
            try app.setSetting(c.name, c.values[k]);
            t.* = try benchSlice(app, io);
        }
        try printTimes(err, c.kind, &times);
    }
    try err.print("peak memory: {d} MB resident (VmHWM), {d} MB allocated\n", .{ peakMb(io), counter.peak.load(.monotonic) >> 20 });
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
    var wall: [16]f64 = undefined;
    var cpu: [16]f64 = undefined;
    var faults: [16]f64 = undefined;
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
        const takes_value = for ([_][]const u8{ "-o", "-s", "--layer", "-m", "--machine", "-f", "--filament", "-p", "--project" }) |o| {
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
        return null;
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
