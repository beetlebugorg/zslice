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
    \\  zslice settings
    \\  zslice demo <out.stl>
    \\
    \\Commands:
    \\  slice     Slice a model and write G-code (default output: stdout).
    \\  preview   Write an SVG picture of one layer.
    \\  profiles  List the built-in profiles and where profile files go.
    \\  profile   Write the settings of one group as a profile file, with
    \\            the options applied. Start a new profile from this output.
    \\  settings  List all settings and their default values.
    \\  demo      Write the demo part as an STL file.
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
    if (!std.mem.eql(u8, cmd, "slice") and !std.mem.eql(u8, cmd, "preview") and !is_profile) {
        fail(err, "unknown command: {s}\n\n{s}", .{ cmd, usage });
    }

    var opts: Options = .{};
    try parseOptions(arena, err, args[2..], &opts);

    // The settings: the profiles, in order, then the -s changes.
    var settings: zslice.Settings = .{};
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
    try err.print("{d} layers, {d:.2} m filament ({d:.1} g), about {d:.0} min, sliced in {d:.0} ms\n", .{
        stats.layer_count,
        stats.filament_mm / 1000,
        stats.filament_g,
        stats.print_time_s / 60,
        ms,
    });
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
