//! The zslice command line tool.

const std = @import("std");
const Io = std.Io;
const zslice = @import("zslice");

const usage =
    \\Usage:
    \\  zslice slice <model.stl> [-o out.gcode] [-s group.name=value ...]
    \\  zslice preview <model.stl> --layer N [-o out.svg] [-s group.name=value ...]
    \\  zslice demo <out.stl>
    \\  zslice settings
    \\
    \\Commands:
    \\  slice     Slice a model and write G-code (default output: stdout).
    \\  preview   Write an SVG picture of one layer.
    \\  demo      Write the demo part as an STL file.
    \\  settings  List all settings and their default values.
    \\
    \\Example:
    \\  zslice slice part.stl -o part.gcode -s project.wall_count=3 -s filament.nozzle_temp=220
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_w: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err = &stderr_w.interface;
    defer err.flush() catch {};

    if (args.len < 2) {
        try err.writeAll(usage);
        std.process.exit(2);
    }
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "settings")) {
        var buf: [4096]u8 = undefined;
        var out_w: Io.File.Writer = .init(.stdout(), io, &buf);
        try listSettings(&out_w.interface);
        try out_w.interface.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "demo")) {
        if (args.len != 3) {
            try err.writeAll(usage);
            std.process.exit(2);
        }
        var m = try zslice.mesh.shapes.demo(gpa);
        defer m.deinit(gpa);
        try writeFile(io, args[2], m, struct {
            fn f(mesh: zslice.mesh.Mesh, w: *Io.Writer) !void {
                try mesh.writeStl(w);
            }
        }.f);
        return;
    }

    if (!std.mem.eql(u8, cmd, "slice") and !std.mem.eql(u8, cmd, "preview")) {
        try err.print("unknown command: {s}\n\n{s}", .{ cmd, usage });
        std.process.exit(2);
    }

    // Parse the options.
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var layer: ?usize = null;
    var settings: zslice.Settings = .{};
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--layer")) {
            if (i + 1 >= args.len) {
                try err.print("{s} needs a value\n", .{a});
                std.process.exit(2);
            }
            i += 1;
            const v = args[i];
            if (std.mem.eql(u8, a, "-o")) {
                output = v;
            } else if (std.mem.eql(u8, a, "--layer")) {
                layer = std.fmt.parseInt(usize, v, 10) catch {
                    try err.print("bad layer number: {s}\n", .{v});
                    std.process.exit(2);
                };
            } else {
                const eq = std.mem.indexOfScalar(u8, v, '=') orelse {
                    try err.print("-s needs group.name=value: {s}\n", .{v});
                    std.process.exit(2);
                };
                settings.set(v[0..eq], v[eq + 1 ..]) catch |e| {
                    try err.print("{s}: {s}\n", .{ v, @errorName(e) });
                    std.process.exit(2);
                };
            }
        } else if (input == null) {
            input = a;
        } else {
            try err.print("unexpected argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }
    const in_path = input orelse {
        try err.writeAll(usage);
        std.process.exit(2);
    };

    const bytes = try Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .unlimited);
    var m = zslice.Mesh.fromStl(gpa, bytes) catch |e| {
        try err.print("{s}: {s}\n", .{ in_path, @errorName(e) });
        std.process.exit(1);
    };
    // The mesh has its own copy of the data, so the file buffer can go now.
    gpa.free(bytes);
    defer m.deinit(gpa);

    const t0 = Io.Clock.awake.now(io);
    var job = zslice.engine.Job.init(gpa, &m, settings) catch |e| {
        try err.print("slice failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer job.deinit();

    if (std.mem.eql(u8, cmd, "preview")) {
        const n = layer orelse {
            try err.writeAll("preview needs --layer N\n");
            std.process.exit(2);
        };
        if (n >= job.layerCount()) {
            try err.print("the part has {d} layers\n", .{job.layerCount()});
            std.process.exit(2);
        }
        var lp = try job.planLayer(n);
        defer lp.deinit();
        try writeOut(io, output, &lp, struct {
            fn f(plan: *zslice.layer.LayerPlan, w: *Io.Writer) !void {
                try zslice.svg.writeLayer(w, plan);
            }
        }.f);
        return;
    }

    const stats = try writeOut(io, output, &job, struct {
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

fn writeFile(io: Io, path: []const u8, value: anytype, comptime func: anytype) !void {
    return writeOut(io, path, value, func);
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
