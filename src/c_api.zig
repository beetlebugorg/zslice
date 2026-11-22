//! The C API. `include/zslice.h` declares these functions. The wasm module
//! exports the same functions.
//!
//! Rules of the API:
//!
//! - Each function returns a status code. 0 is success.
//! - Objects (meshes, settings) are opaque pointers. Each `_new` or `_load`
//!   function has a `_free` function.
//! - The library allocates its own memory. Native builds use the Zig SMP
//!   allocator (thread-safe), and wasm builds use the wasm allocator.

const std = @import("std");
const builtin = @import("builtin");
const zs = @import("root.zig");
const Writer = std.Io.Writer;

pub const is_wasm = builtin.cpu.arch.isWasm();
pub const gpa = if (zs.parallel.wasm_pool) zs.wasm_heap.allocator else if (is_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;

pub const Status = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    invalid_argument = 2,
    invalid_mesh = 3,
    empty_mesh = 4,
    unknown_setting = 5,
    invalid_value = 6,
    invalid_settings = 7,
    part_too_large = 8,
    write_failed = 9,
    canceled = 10,
    busy = 11,
    no_model = 12,
    no_result = 13,
    out_of_range = 14,
    not_supported = 15,
    gpu_failed = 16,
    part_too_thin = 17,
};

pub fn status(e: anyerror) c_int {
    const s: Status = switch (e) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidStl, error.InvalidMesh, error.NotThreeMf, error.Corrupt => .invalid_mesh,
        error.Unsupported => .not_supported,
        error.EmptyMesh => .empty_mesh,
        error.UnknownSetting => .unknown_setting,
        error.InvalidValue, error.InvalidImage => .invalid_value,
        error.InvalidSettings => .invalid_settings,
        error.PartTooLarge => .part_too_large,
        error.PartTooThin => .part_too_thin,
        error.WriteFailed => .write_failed,
        error.Canceled => .canceled,
        error.Busy, error.FrameBusy => .busy,
        error.NoModel => .no_model,
        error.NoResult => .no_result,
        error.OutOfRange => .out_of_range,
        error.NoVulkan, error.NoD3D12 => .not_supported,
        error.NoDevice, error.VulkanFailed, error.SurfaceFailed, error.D3D12Failed => .gpu_failed,
        else => .invalid_argument,
    };
    return @intFromEnum(s);
}

pub const ok: c_int = @intFromEnum(Status.ok);

pub const Stats = extern struct {
    layer_count: u32,
    retractions: u32,
    filament_mm: f64,
    filament_g: f64,
    print_time_s: f64,
    travel_mm: f64,
};

pub fn cStats(s: zs.Stats) Stats {
    return .{
        .layer_count = s.layer_count,
        .retractions = s.retractions,
        .filament_mm = s.filament_mm,
        .filament_g = s.filament_g,
        .print_time_s = s.print_time_s,
        .travel_mm = s.travel_mm,
    };
}

/// Settings and the memory for their string values.
const CSettings = struct {
    settings: zs.Settings = .{},
    strings: std.heap.ArenaAllocator,
};

export fn zs_version() [*:0]const u8 {
    return zs.version;
}

/// A status in words for a person, with what to do where it helps. The
/// same texts in each app.
export fn zs_status_message(code: c_int) [*:0]const u8 {
    const s = std.enums.fromInt(Status, code) orelse return "Something went wrong.";
    return switch (s) {
        .ok => "OK.",
        .out_of_memory => "Out of memory. Close other programs or tabs, or use a smaller model or fewer parts.",
        .invalid_argument => "The app asked the core for something it cannot do.",
        .invalid_mesh => "The file is not an STL or 3MF model, or it is damaged. Export it again from your CAD program, or open another file.",
        .empty_mesh => "The model has no solid part (no closed surface to print). Check that it is a solid in your CAD program.",
        .unknown_setting => "This version of zslice does not know the setting.",
        .invalid_value => "The value does not fit the setting.",
        .invalid_settings => "The settings cannot make a print. Check the layer height, the line width, and the nozzle.",
        .part_too_large => "A part does not fit the printer: it is higher than the printer, or larger than the bed. The plate shows in the view, but it does not print. Lay the part on a side, turn it, scale it down, or cut it (Cut on the part card).",
        .write_failed => "The file did not write.",
        .canceled => "Canceled.",
        .busy => "A slice is running. Try again in a moment.",
        .no_model => "No model. Open a model first.",
        .no_result => "No slice yet. Wait for the slice to finish.",
        .out_of_range => "Out of range.",
        .not_supported => "This is not supported here.",
        .gpu_failed => "The 3D view did not start. Update the graphics driver, or use the 2D view.",
        .part_too_thin => "The part is lower than half of the first layer, so no layer cuts it. Scale it up, or lower the first layer height.",
    };
}

export fn zs_status_string(code: c_int) [*:0]const u8 {
    const s = std.enums.fromInt(Status, code) orelse return "unknown status";
    return @tagName(s);
}

/// All setting names ("group.name"), one on each line.
export fn zs_setting_names() [*:0]const u8 {
    return setting_names;
}

const setting_names: [:0]const u8 = blk: {
    var text: [:0]const u8 = "";
    @setEvalBranchQuota(2_000_000);
    for (@typeInfo(zs.Settings).@"struct".fields) |g| {
        for (@typeInfo(g.type).@"struct".fields) |f| {
            if (f.type == [zs.settings.max_nozzles]zs.settings.Nozzle) {
                // The settings of each nozzle after the first.
                for (1..zs.settings.max_nozzles) |k| {
                    for (@typeInfo(zs.settings.Nozzle).@"struct".fields) |nf| text = text ++ std.fmt.comptimePrint("{s}.{s}.{d}.{s}\n", .{ g.name, f.name, k, nf.name });
                }
                continue;
            }
            text = text ++ g.name ++ "." ++ f.name ++ "\n";
        }
    }
    break :blk text;
};

export fn zs_mesh_load_stl(data: ?[*]const u8, len: usize, out: ?*?*zs.Mesh) c_int {
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const m = gpa.create(zs.Mesh) catch |e| return status(e);
    m.* = zs.Mesh.fromStl(gpa, d[0..len]) catch |e| {
        gpa.destroy(m);
        return status(e);
    };
    o.* = m;
    return ok;
}

/// `xyz` has 9 floats for each triangle: x, y, z of each of 3 vertices.
export fn zs_mesh_from_triangles(xyz: ?[*]const f32, triangle_count: usize, out: ?*?*zs.Mesh) c_int {
    const d = xyz orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const m = gpa.create(zs.Mesh) catch |e| return status(e);
    m.* = zs.Mesh.fromTriangles(gpa, d[0 .. triangle_count * 9]) catch |e| {
        gpa.destroy(m);
        return status(e);
    };
    o.* = m;
    return ok;
}

export fn zs_mesh_free(mesh: ?*zs.Mesh) void {
    const m = mesh orelse return;
    m.deinit(gpa);
    gpa.destroy(m);
}

export fn zs_settings_new(out: ?*?*CSettings) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const s = gpa.create(CSettings) catch |e| return status(e);
    s.* = .{ .strings = .init(gpa) };
    o.* = s;
    return ok;
}

/// Sets one setting. `key` is "group.name", for example
/// "project.wall_count". The value is text. The library copies it.
export fn zs_settings_set(settings: ?*CSettings, key: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const s = settings orelse return @intFromEnum(Status.invalid_argument);
    const k = std.mem.span(key orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    // String settings keep a pointer to the value, so it must live as long
    // as the settings.
    const copy = s.strings.allocator().dupe(u8, v) catch |e| return status(e);
    s.settings.set(k, copy) catch |e| return status(e);
    return ok;
}

export fn zs_settings_free(settings: ?*CSettings) void {
    const s = settings orelse return;
    s.strings.deinit();
    gpa.destroy(s);
}

/// The callback gets the G-code in parts. It returns 0 on success. Any
/// other value stops the slice with status write_failed.
pub const WriteFn = *const fn (user: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) c_int;

/// A writer that sends its data to a C callback.
const CallbackWriter = struct {
    interface: Writer,
    write: WriteFn,
    user: ?*anyopaque,

    fn send(self: *CallbackWriter, bytes: []const u8) Writer.Error!void {
        if (bytes.len == 0) return;
        if (self.write(self.user, bytes.ptr, bytes.len) != 0) return error.WriteFailed;
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *CallbackWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.send(w.buffer[0..w.end]);
        w.end = 0;
        if (data.len == 1) {
            for (0..splat) |_| try self.send(data[0]);
            return data[0].len * splat;
        }
        try self.send(data[0]);
        return data[0].len;
    }
};

/// Slices the mesh and sends the G-code to `write` as it is made.
export fn zs_slice(mesh: ?*const zs.Mesh, settings: ?*const CSettings, write: ?WriteFn, user: ?*anyopaque, stats: ?*Stats) c_int {
    const m = mesh orelse return @intFromEnum(Status.invalid_argument);
    const w = write orelse return @intFromEnum(Status.invalid_argument);
    const s: zs.Settings = if (settings) |cs| cs.settings else .{};
    var buf: [64 * 1024]u8 = undefined;
    var cw: CallbackWriter = .{
        .interface = .{ .buffer = &buf, .vtable = &.{ .drain = CallbackWriter.drain } },
        .write = w,
        .user = user,
    };
    const result = zs.slice(gpa, m, s, &cw.interface) catch |e| return status(e);
    cw.interface.flush() catch |e| return status(e);
    if (stats) |st| st.* = cStats(result);
    return ok;
}

/// Slices the mesh into one buffer. Free the buffer with zs_buffer_free.
export fn zs_slice_to_buffer(mesh: ?*const zs.Mesh, settings: ?*const CSettings, out: ?*?[*]u8, out_len: ?*usize, stats: ?*Stats) c_int {
    const m = mesh orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const ol = out_len orelse return @intFromEnum(Status.invalid_argument);
    const s: zs.Settings = if (settings) |cs| cs.settings else .{};
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const result = zs.slice(gpa, m, s, &aw.writer) catch |e| return status(e);
    const bytes = aw.toOwnedSlice() catch |e| return status(e);
    o.* = bytes.ptr;
    ol.* = bytes.len;
    if (stats) |st| st.* = cStats(result);
    return ok;
}

export fn zs_buffer_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

/// Memory for the host to pass data in (wasm). Free it with zs_free.
export fn zs_alloc(len: usize) ?[*]u8 {
    const b = gpa.alloc(u8, len) catch return null;
    return b.ptr;
}

export fn zs_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

/// The wasm module with threads: the host calls this on each thread that
/// it starts, with a number (0, 1, ...), the top of a stack for the thread,
/// and memory for its thread-local data (`zs_thread_tls_size` bytes, from
/// zs_alloc). The call does not return: the thread waits for work of a
/// slice (see parallel.zig).
fn threadRun(index: u32, stack_top: [*]u8, tls: [*]u8) callconv(.c) void {
    // The instance of the thread starts with the stack of the first
    // instance. No code can use the stack before this.
    asm volatile (
        \\ local.get %[ptr]
        \\ global.set __stack_pointer
        :
        : [ptr] "r" (stack_top),
    );
    threadMain(index, tls);
}

extern fn __wasm_init_tls(memory: [*]u8) void;

noinline fn threadMain(index: u32, tls: [*]u8) void {
    __wasm_init_tls(tls);
    zs.parallel.workerMain(index);
}

fn threadTlsSize() callconv(.c) u32 {
    return asm volatile (
        \\ .globaltype __tls_size, i32, immutable
        \\ global.get __tls_size
        \\ local.set %[ret]
        : [ret] "=r" (-> u32),
    );
}

comptime {
    if (zs.parallel.wasm_pool) {
        @export(&threadRun, .{ .name = "zs_thread_run" });
        @export(&threadTlsSize, .{ .name = "zs_thread_tls_size" });
    }
    _ = @import("c_api/app.zig");
    _ = @import("c_api/view.zig");
    _ = @import("c_api/printers.zig");
    _ = @import("c_api/project.zig");
    _ = @import("c_api/set.zig");
    _ = @import("c_api/farm.zig");
    _ = @import("c_api/sign.zig");
    _ = @import("c_api/link.zig");
    _ = @import("c_api/gcode.zig");
    _ = @import("c_api/paint.zig");
    _ = @import("c_api/label.zig");
}

test "C API: slice a box to a buffer and with a callback" {
    var m: ?*zs.Mesh = null;
    const box = [_]f32{
        // Two triangles of each of 6 faces of a 10 mm cube.
        0, 0, 0, 0, 10, 0, 10, 10, 0, 0, 0, 0, 10, 10, 0, 10, 0, 0, // bottom
        0, 0, 10, 10, 0, 10, 10, 10, 10, 0, 0, 10, 10, 10, 10, 0, 10, 10, // top
        0, 0, 0, 10, 0, 0, 10, 0, 10, 0, 0, 0, 10, 0, 10, 0, 0, 10, // front
        0, 10, 0, 0, 10, 10, 10, 10, 10, 0, 10, 0, 10, 10, 10, 10, 10, 0, // back
        0, 0, 0, 0, 0, 10, 0, 10, 10, 0, 0, 0, 0, 10, 10, 0, 10, 0, // left
        10, 0, 0, 10, 10, 0, 10, 10, 10, 10, 0, 0, 10, 10, 10, 10, 0, 10, // right
    };
    try std.testing.expectEqual(ok, zs_mesh_from_triangles(&box, 12, &m));
    defer zs_mesh_free(m);

    var s: ?*CSettings = null;
    try std.testing.expectEqual(ok, zs_settings_new(&s));
    defer zs_settings_free(s);
    try std.testing.expectEqual(ok, zs_settings_set(s, "project.wall_count", "3"));
    try std.testing.expectEqual(@intFromEnum(Status.unknown_setting), zs_settings_set(s, "project.nope", "3"));

    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    var st: Stats = undefined;
    try std.testing.expectEqual(ok, zs_slice_to_buffer(m, s, &ptr, &len, &st));
    defer zs_buffer_free(ptr, len);
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], ";LAYER:0\n") != null);

    const Counter = struct {
        fn f(user: ?*anyopaque, _: [*]const u8, n: usize) callconv(.c) c_int {
            const total: *usize = @ptrCast(@alignCast(user.?));
            total.* += n;
            return 0;
        }
    };
    var total: usize = 0;
    try std.testing.expectEqual(ok, zs_slice(m, s, Counter.f, &total, null));
    try std.testing.expectEqual(len, total);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zs_setting_names()), "filament.nozzle_temp\n") != null);
}
