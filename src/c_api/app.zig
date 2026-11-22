//! The C API of the app core: `include/zslice-app.h`, without the 3D
//! view. Each function checks its pointers and calls `App` (src/app.zig).
//! The rules of the API are in c_api.zig.

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const status = c.status;
const ok = c.ok;
const Stats = c.Stats;
const cStats = c.cStats;
const gpa = c.gpa;
const Writer = std.Io.Writer;

const app_mod = zs.app;
const App = app_mod.App;

/// Notes a change for the undo list (see app/history.zig): the name of one
/// setting, or null for more; `plate`: the plate changed.
fn noted(app: *App, key: ?[]const u8, plate: bool) void {
    app.undo.note(app.gpa, key, plate);
}

pub export fn zs_app_new(event_fn: ?app_mod.EventFn, user: ?*anyopaque, out: ?*?*App) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = App.create(gpa, event_fn, user) catch |e| return status(e);
    return ok;
}

/// wasm: the host cannot give a C function pointer, so the events go to the
/// import env.zs_web_event of the module. A slice runs on the calling
/// thread there, so the events come while zs_app_slice runs.
const web_events = struct {
    extern "env" fn zs_web_event(event: c_int, progress: f64, status: c_int) void;
    fn forward(_: ?*anyopaque, event: c_int, progress: f64, st: c_int) callconv(.c) void {
        zs_web_event(event, progress, st);
    }
    fn new(out: ?*?*App) callconv(.c) c_int {
        return zs_app_new(forward, null, out);
    }
};

comptime {
    if (c.is_wasm) @export(&web_events.new, .{ .name = "zs_app_new_web" });
}

pub export fn zs_app_free(a: ?*App) void {
    const app = a orelse return;
    app.destroy();
}

/// Frees the memory of the app that only a faster next slice uses.
export fn zs_app_trim(a: ?*App) void {
    const app = a orelse return;
    app.trim();
}

export fn zs_app_state(a: ?*const App) c_int {
    const app = a orelse return 0;
    return @intFromEnum(app.getState());
}

pub export fn zs_app_load_stl(a: ?*App, name: ?[*:0]const u8, data: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    const n = if (name) |p| std.mem.span(p) else "";
    app.loadStl(n, d[0..len]) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

pub const ModelInfo = extern struct {
    triangles: u64,
    size_x: f64,
    size_y: f64,
    size_z: f64,
};

export fn zs_app_model_info(a: ?*const App, out: ?*ModelInfo) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const info = app.modelInfo() orelse return @intFromEnum(Status.no_model);
    o.* = .{ .triangles = info.triangles, .size_x = info.size[0], .size_y = info.size[1], .size_z = info.size[2] };
    return ok;
}

pub const SettingInfo = extern struct {
    name: [*:0]const u8,
    group: [*:0]const u8,
    section: [*:0]const u8,
    label: [*:0]const u8,
    doc: [*:0]const u8,
    kind: c_int,
    multiline: c_int,
    choices: [*:0]const u8,
    unit: [*:0]const u8,
    default_value: [*:0]const u8,
    slider_min: f64,
    slider_max: f64,
    limit_min: f64,
    limit_max: f64,
    slider_step: f64,
    per_layer: c_int,
    per_part: c_int,
    nozzle: c_int,
};

/// The text of a value of setting `name`, as an editor shows it (a ratio as
/// a percentage, a line width of 0 as "auto", the first line of a G-code);
/// with_unit != 0 adds the unit ("0.8 mm", "1 layer"). The same buffer
/// rules as zs_app_setting_get.
export fn zs_setting_display(name: ?[*:0]const u8, value: ?[*:0]const u8, with_unit: c_int, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const s = app_mod.setting_text.find(std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) orelse return @intFromEnum(Status.unknown_setting);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.setting_text.display(s, std.mem.span(value orelse return @intFromEnum(Status.invalid_argument)), with_unit != 0, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The core value of the text of an editor of setting `name` ("auto" is
/// 0, a percentage is a ratio). ZS_INVALID_VALUE: a number setting with a
/// text that is not a number. The same buffer rules as zs_app_setting_get.
export fn zs_setting_parse(name: ?[*:0]const u8, text: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const s = app_mod.setting_text.find(std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) orelse return @intFromEnum(Status.unknown_setting);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.setting_text.parse(s, std.mem.span(text orelse return @intFromEnum(Status.invalid_argument)), &aw.writer) catch |e| return switch (e) {
        error.InvalidValue => @intFromEnum(Status.invalid_value),
        else => @intFromEnum(Status.out_of_memory),
    };
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The source of a value as a short tag: level (enum zs_level), the name
/// of its profile, and its formula or NULL. "Global", the profile name,
/// "This print", "This part", or "= formula". The same buffer rules as
/// zs_app_setting_get.
export fn zs_setting_source_text(level: c_int, profile: ?[*:0]const u8, formula: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const f: ?[]const u8 = if (formula) |x| std.mem.span(x) else null;
    app_mod.setting_text.source(level, if (profile) |p| std.mem.span(p) else "", f, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The settings that match a search query, best first, at most max: their
/// indices (zs_setting_get_info) in out_index, and their scores in
/// out_score (either can be NULL). part_only != 0: only the settings that
/// a part can have of its own. Returns the count. The rules and the words
/// of other slicers are in src/app/setting_search.zig.
export fn zs_setting_search(query: ?[*:0]const u8, part_only: c_int, out_index: ?[*]u32, out_score: ?[*]f64, max: usize) usize {
    const q = std.mem.span(query orelse return 0);
    var buf: [512]zs.app.setting_search.Hit = undefined;
    const n = zs.app.setting_search.search(q, part_only != 0, buf[0..@min(max, buf.len)]);
    for (buf[0..n], 0..) |h, i| {
        if (out_index) |o| o[i] = h.index;
        if (out_score) |o| o[i] = h.score;
    }
    return n;
}

const PStatus = zs.app.printer_status.Status;

fn kindOf(kind: c_int) ?zs.app.printer_status.Kind {
    return switch (kind) {
        1 => .octoprint,
        2 => .printdeck,
        3 => .moonraker,
        4 => .bambu,
        else => null,
    };
}

/// The paths of the status of a printer of `kind` (1 OctoPrint, 2
/// printdeck, 3 Moonraker), one on each line, to GET in order. Static.
export fn zs_printer_status_paths(kind: c_int) [*:0]const u8 {
    const k = kindOf(kind) orelse return "";
    return zs.app.printer_status.paths(k).ptr;
}

/// A new, empty printer status. Free it with zs_printer_status_free.
export fn zs_printer_status_new() ?*PStatus {
    const s = gpa.create(PStatus) catch return null;
    s.* = .init(gpa);
    return s;
}

export fn zs_printer_status_free(s: ?*PStatus) void {
    const st = s orelse return;
    st.deinit();
    gpa.destroy(st);
}

/// Reads the reply of a path (see zs_printer_status_paths). A reply that is
/// not JSON changes nothing.
export fn zs_printer_status_feed(s: ?*PStatus, kind: c_int, path: ?[*:0]const u8, body: ?[*]const u8, len: usize) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const k = kindOf(kind) orelse return @intFromEnum(Status.invalid_argument);
    const b = body orelse return @intFromEnum(Status.invalid_argument);
    st.feed(k, std.mem.span(path orelse return @intFromEnum(Status.invalid_argument)), b[0..len]) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

pub const PrinterRoll = extern struct {
    id: [*:0]const u8,
    name: [*:0]const u8,
    material: [*:0]const u8,
    color: [*:0]const u8,
    left: f64,
};

pub const PrinterInfo = extern struct {
    state: [*:0]const u8,
    bed_x: f64,
    bed_y: f64,
    height: f64,
    nozzle: f64,
    material: [*:0]const u8,
    diameter: f64,
    spool: PrinterRoll,
    spool_price: f64,
    spool_full: f64,
    roll_count: usize,
    max_velocity: f64,
    max_accel: f64,
    corner_velocity: f64,
    max_z_velocity: f64,
    max_z_accel: f64,
    job: [*:0]const u8,
    progress: f64,
    time_left: f64,
    layer: c_int,
    layers: c_int,
};

fn rollOut(r: zs.app.printer_status.Roll) PrinterRoll {
    return .{ .id = r.id.ptr, .name = r.name.ptr, .material = r.material.ptr, .color = r.color.ptr, .left = r.left };
}

/// The status read so far. The strings stay valid until the next feed or
/// the free.
export fn zs_printer_status_get(s: ?*const PStatus, out: ?*PrinterInfo) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = .{
        .state = st.state.ptr,
        .bed_x = st.bed_x,
        .bed_y = st.bed_y,
        .height = st.height,
        .nozzle = st.nozzle,
        .material = st.material.ptr,
        .diameter = st.diameter,
        .spool = rollOut(st.spool),
        .spool_price = st.spool_price,
        .spool_full = st.spool_full,
        .roll_count = st.rolls.len,
        .max_velocity = st.max_velocity,
        .max_accel = st.max_accel,
        .corner_velocity = st.corner_velocity,
        .max_z_velocity = st.max_z_velocity,
        .max_z_accel = st.max_z_accel,
        .job = st.job.ptr,
        .progress = st.progress,
        .time_left = st.time_left,
        .layer = st.layer,
        .layers = st.layers,
    };
    return ok;
}

/// Roll i of the printer (i < roll_count).
/// Why the print failed or stopped ("" for none), valid until the next
/// feed.
export fn zs_printer_status_message(s: ?*const PStatus) [*:0]const u8 {
    const x = s orelse return "";
    return x.message.ptr;
}

/// The spools that the printer has loaded (the trays of its AMS and its
/// external spools) as the JSON of a printdeck, {"filaments": [...]}, for
/// zs_app_filaments_from_printer. ZS_NO_RESULT when the printer has not
/// told its spools. The same buffer rules as zs_app_setting_get.
export fn zs_printer_status_filaments(s: ?*const PStatus, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    if (!st.has_trays) return @intFromEnum(Status.no_result);
    const text = st.filamentsJson(gpa) catch return @intFromEnum(Status.out_of_memory);
    defer gpa.free(text);
    if (out_len) |l| l.* = text.len;
    if (buf) |b| if (cap > 0) {
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    };
    return ok;
}

/// The state for the farm (enum zs_farm_printer_state) from the state text.
export fn zs_printer_status_farm_state(s: ?*const PStatus) c_int {
    const x = s orelse return 0;
    return zs.app.printer_status.farmState(x.state);
}

export fn zs_printer_status_roll(s: ?*const PStatus, i: usize, out: ?*PrinterRoll) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= st.rolls.len) return @intFromEnum(Status.out_of_range);
    o.* = rollOut(st.rolls[i]);
    return ok;
}

pub const PrinterHeat = extern struct {
    nozzle: f64,
    nozzle_target: f64,
    bed: f64,
    bed_target: f64,
    chamber: f64,
};

/// The temperatures in °C; NaN when not known.
export fn zs_printer_status_heat(s: ?*const PStatus, out: ?*PrinterHeat) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const h = st.heat;
    o.* = .{ .nozzle = h.nozzle, .nozzle_target = h.nozzle_target, .bed = h.bed, .bed_target = h.bed_target, .chamber = h.chamber };
    return ok;
}

/// The paths of the camera of a printer of `kind`, one on each line, to
/// GET once. Static. Feed the replies to zs_printer_status_feed.
export fn zs_printer_camera_paths(kind: c_int) [*:0]const u8 {
    const k = kindOf(kind) orelse return "";
    return zs.app.printer_status.cameraPaths(k).ptr;
}

pub const PrinterCamera = extern struct {
    stream: [*:0]const u8,
    snapshot: [*:0]const u8,
    flip_h: c_int,
    flip_v: c_int,
    rotation: c_int,
};

/// The camera of the printer. The strings stay valid until the next feed
/// or the free.
export fn zs_printer_status_camera(s: ?*const PStatus, out: ?*PrinterCamera) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const cam = st.camera;
    o.* = .{ .stream = cam.stream.ptr, .snapshot = cam.snapshot.ptr, .flip_h = @intFromBool(cam.flip_h), .flip_v = @intFromBool(cam.flip_v), .rotation = cam.rotation };
    return ok;
}

/// The camera kind of a Bambu Lab model of the library ("bambu-lab-x2d"):
/// 0 not known, 1 RTSPS on port 322, 2 JPEG frames on port 6000.
export fn zs_bambu_camera_kind(model_id: ?[*:0]const u8) c_int {
    const m = model_id orelse return 0;
    return @intFromEnum(zs.bambu.cameraOf(std.mem.span(m)));
}

/// The 80 bytes that open the JPEG camera stream of port 6000, for the
/// access code `code`.
export fn zs_bambu_camera_auth(code: ?[*:0]const u8, out: ?*[80]u8) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = zs.bambu.jpegAuth(std.mem.span(code orelse return @intFromEnum(Status.invalid_argument)));
    return ok;
}

/// The bytes of the stream of a Bambu Lab printer camera (port 6000), in,
/// and the whole JPEG frames, out.
const JpegReader = zs.bambu.JpegReader;

export fn zs_bambu_jpeg_reader_new() ?*JpegReader {
    const r = gpa.create(JpegReader) catch return null;
    r.* = .{};
    return r;
}

export fn zs_bambu_jpeg_reader_free(r: ?*JpegReader) void {
    const x = r orelse return;
    x.deinit(gpa);
    gpa.destroy(x);
}

export fn zs_bambu_jpeg_reader_feed(r: ?*JpegReader, bytes: ?[*]const u8, len: usize) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    const b = bytes orelse return @intFromEnum(Status.invalid_argument);
    x.feed(gpa, b[0..len]) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

/// 1 and a frame (valid until the next call), 0 when more bytes must come,
/// or a negative error for a stream that is not of frames.
export fn zs_bambu_jpeg_reader_next(r: ?*JpegReader, jpeg: ?*?[*]const u8, len: ?*usize) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    const f = (x.next() catch return @intFromEnum(Status.invalid_argument)) orelse return 0;
    if (jpeg) |p| p.* = f.ptr;
    if (len) |p| p.* = f.len;
    return 1;
}

/// MQTT 3.1.1 for a Bambu Lab printer (src/mqtt.zig): the packets to
/// write, and a reader of the packets that come. A link that only reads
/// makes no PUBLISH.
export fn zs_mqtt_connect_packet(client_id: ?[*:0]const u8, user: ?[*:0]const u8, password: ?[*:0]const u8, keepalive_s: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const n = out_len orelse return @intFromEnum(Status.invalid_argument);
    const span = struct {
        fn f(s: ?[*:0]const u8) []const u8 {
            return if (s) |x| std.mem.span(x) else "";
        }
    }.f;
    const p = zs.mqtt.connectPacket(gpa, span(client_id), span(user), span(password), @intCast(std.math.clamp(keepalive_s, 0, 65535))) catch return @intFromEnum(Status.out_of_memory);
    o.* = p.ptr;
    n.* = p.len;
    return ok;
}

export fn zs_mqtt_subscribe_packet(topic: ?[*:0]const u8, packet_id: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const n = out_len orelse return @intFromEnum(Status.invalid_argument);
    const t = topic orelse return @intFromEnum(Status.invalid_argument);
    const p = zs.mqtt.subscribePacket(gpa, @intCast(std.math.clamp(packet_id, 1, 65535)), std.mem.span(t)) catch return @intFromEnum(Status.out_of_memory);
    o.* = p.ptr;
    n.* = p.len;
    return ok;
}

pub const MqttPacket = extern struct {
    kind: c_int,
    return_code: c_int,
    topic: ?[*]const u8,
    topic_len: usize,
    payload: ?[*]const u8,
    payload_len: usize,
};

const MqttReader = zs.mqtt.Reader;

export fn zs_mqtt_reader_new() ?*MqttReader {
    const r = gpa.create(MqttReader) catch return null;
    r.* = .{};
    return r;
}

export fn zs_mqtt_reader_free(r: ?*MqttReader) void {
    const x = r orelse return;
    x.deinit(gpa);
    gpa.destroy(x);
}

export fn zs_mqtt_reader_feed(r: ?*MqttReader, bytes: ?[*]const u8, len: usize) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    const b = bytes orelse return @intFromEnum(Status.invalid_argument);
    x.feed(gpa, b[0..len]) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

/// 1 and a packet (its slices valid until the next call), 0 when more bytes
/// must come, or a negative error for a stream that is not MQTT.
export fn zs_mqtt_reader_next(r: ?*MqttReader, out: ?*MqttPacket) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const p = (x.next() catch return @intFromEnum(Status.invalid_argument)) orelse return 0;
    o.* = .{ .kind = p.kind, .return_code = p.return_code, .topic = p.topic.ptr, .topic_len = p.topic.len, .payload = p.payload.ptr, .payload_len = p.payload.len };
    return 1;
}

/// Applies the status of a printer to the settings of the app. what: 1
/// the machine (the bed, the height, the nozzle, and the motion limits
/// that the printer gives, each only when known), 2 the filament (the
/// built-in profile of its material, the name of the roll, the diameter,
/// and the color), 3 both. A material with no built-in profile keeps the
/// profile, and sets only the name, the material, the diameter, and the
/// color. Noted in the history as one step.
export fn zs_app_apply_printer_status(a: ?*App, s: ?*const PStatus, what: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    var buf: [64]u8 = undefined;
    const Num = struct {
        fn set(ap: *App, b: []u8, name: []const u8, v: f64) void {
            if (!(v > 0)) return;
            const t = std.fmt.bufPrint(b, "{d}", .{v}) catch return;
            ap.setSetting(name, t) catch {};
        }
    };
    if (what & 1 != 0) {
        Num.set(app, &buf, "machine.bed_size_x", st.bed_x);
        Num.set(app, &buf, "machine.bed_size_y", st.bed_y);
        Num.set(app, &buf, "machine.max_height", st.height);
        Num.set(app, &buf, "machine.nozzle_diameter", st.nozzle);
        // The motion limits, for a time estimate that matches the printer
        // (the speed of the print stays a setting of zslice).
        Num.set(app, &buf, "machine.max_accel", st.max_accel);
        Num.set(app, &buf, "machine.corner_speed", st.corner_velocity);
        Num.set(app, &buf, "machine.max_z_speed", st.max_z_velocity);
        Num.set(app, &buf, "machine.max_z_accel", st.max_z_accel);
    }
    if (what & 2 != 0) {
        const material = if (st.material.len > 0) st.material else st.spool.material;
        // The diameter belongs to the printer: a new base profile keeps it,
        // unless the printer gives one.
        const keep_diameter = app.settings.filament.diameter;
        if (material.len > 0 and material.len < 40) {
            var low: [40]u8 = undefined;
            const lower = std.ascii.lowerString(&low, material);
            var pb: [80]u8 = undefined;
            const text = std.fmt.bufPrint(&pb, "extends = \"generic-{s}\"\n", .{lower}) catch "";
            var diag: zs.profile.Diagnostic = .{};
            app.applyProfile(.filament, "saved", text, &diag) catch {};
            var up: [40]u8 = undefined;
            app.setSetting("filament.material", std.ascii.upperString(&up, material)) catch {};
        }
        const name = if (st.spool.name.len > 0) st.spool.name else material;
        if (name.len > 0) app.setSetting("filament.name", name) catch {};
        Num.set(app, &buf, "filament.diameter", if (st.diameter > 0) st.diameter else keep_diameter);
        const color = if (st.spool.color.len > 0) st.spool.color else "";
        if (color.len > 0) app.setSetting("filament.color", color) catch {};
    }
    noted(app, null, false);
    return ok;
}

/// A .gcode.3mf file for a Bambu Lab printer, with the G-code as plate 1
/// and its MD5 (see src/bambu.zig). Free the bytes with zs_buffer_free.
export fn zs_bambu_file(gcode: ?[*]const u8, len: usize, title: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const g = gcode orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const bytes = zs.bambu.gcode3mf(gpa, g[0..len], if (title) |t| std.mem.span(t) else "zslice") catch return @intFromEnum(Status.out_of_memory);
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

pub const BambuPlate = extern struct {
    title: ?[*:0]const u8,
    seconds: f64,
    grams: f64,
    meters: f64,
    material: ?[*:0]const u8,
    color: ?[*:0]const u8,
    nozzle: f64,
};

/// zs_bambu_file with the facts of the plate in
/// Metadata/slice_info.config (its time, grams, and filament), as a
/// printdeck reads them. Free the bytes with zs_buffer_free.
export fn zs_bambu_file_plate(gcode: ?[*]const u8, len: usize, plate: ?*const BambuPlate, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const g = gcode orelse return @intFromEnum(Status.invalid_argument);
    const p = plate orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const span = struct {
        fn f(s: ?[*:0]const u8) []const u8 {
            return if (s) |x| std.mem.span(x) else "";
        }
    }.f;
    const bytes = zs.bambu.gcode3mfPlate(gpa, g[0..len], if (p.title) |t| std.mem.span(t) else "zslice", .{
        .seconds = p.seconds,
        .grams = p.grams,
        .meters = p.meters,
        .material = span(p.material),
        .color = span(p.color),
        .nozzle = p.nozzle,
    }) catch return @intFromEnum(Status.out_of_memory);
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

/// A .gcode.3mf file of the last slice of the app for a Bambu Lab printer
/// (see zs_bambu_file), with the filaments that the print uses in
/// Metadata/slice_info.config: their slots, types, colors, and weights.
/// Free the bytes with zs_buffer_free. The core only makes the file; it
/// never sends it.
export fn zs_app_bambu_file(a: ?*const App, title: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = app.exactGcode() orelse return @intFromEnum(Status.no_result);
    return bambuFileOf(app, g, title, out, out_len);
}

/// zs_app_bambu_file with the G-code of the shell in place of the G-code
/// of the last slice (the same G-code with the signature of the app), and
/// the filaments of the last slice.
export fn zs_app_bambu_file_gcode(a: ?*const App, gcode: ?[*]const u8, len: usize, title: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = gcode orelse return @intFromEnum(Status.invalid_argument);
    return bambuFileOf(app, g[0..len], title, out, out_len);
}

/// The time of the first layer (s): the start of the first path of the
/// second layer; the print time for a print of one layer.
fn firstLayerTime(app: *const App, total: f64) f64 {
    const tp = &app.toolpaths;
    if (tp.layer_ends.items.len < 2) return total;
    const p = tp.layer_ends.items[0];
    if (p >= tp.path_start_time.items.len) return total;
    return tp.path_start_time.items[p];
}

fn bambuFileOf(app: *const App, g: []const u8, title: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const st = app.result() orelse return @intFromEnum(Status.no_result);
    var list: [zs.filaments.max_slots]zs.bambu.FilamentUse = undefined;
    var n: usize = 0;
    for (0..app_mod.filament_slots.count(app)) |k| {
        if (k >= list.len) break;
        const f = app_mod.filament_slots.get(app, k) orelse continue;
        if (st.slot_g[k] <= 0) continue;
        const p = app.settings.project;
        const count = app_mod.filament_slots.count(app);
        const support = p.support != .off;
        const sup_slot = zs.filaments.pathSlot(.support, p, count);
        const iface_slot = zs.filaments.pathSlot(.support_interface, p, count);
        const part_slot = zs.filaments.slotOf(p.filament, count);
        list[n] = .{
            .id = @intCast(k + 1),
            .kind = f.material,
            .color = f.color,
            .meters = st.slot_mm[k] / 1000,
            .grams = st.slot_g[k],
            .nozzle = f.nozzle,
            // A filament for the support only does not print the parts
            // (a part of another filament still does).
            .for_support = support and (sup_slot == k or iface_slot == k),
            .for_object = !(support and p.support_filament > 0 and (sup_slot == k or iface_slot == k) and part_slot != k),
            // The filament id of the spool in the printer.
            .idx = if (app.slot_marks[k].printer) app.slot_marks[k].idx() else "",
        };
        n += 1;
    }
    const m = app.settings.machine;
    const bytes = zs.bambu.gcode3mfInfo(gpa, g, if (title) |t| std.mem.span(t) else "zslice", .{
        .filaments = list[0..n],
        .seconds = st.print_time_s,
        // The hotends of the model (a profile saved before zslice knew
        // two nozzles says 1): the printer refuses a file of another count.
        .nozzles = if (zs.printers.bambu(m.model)) |b| @max(b.nozzles, m.nozzles) else m.nozzles,
        .model_id = if (zs.printers.bambu(m.model)) |b| b.code else "",
        .nozzle = m.nozzle_diameter,
        .support_used = app.settings.project.support != .off,
        .printer_model = if (zs.printers.bambu(m.model)) |b| b.name else "",
        .bed_type = m.bed_type.studioName(),
        .nozzle_type = @tagName(m.nozzle_type),
        .nozzle_flow = if (m.nozzle_flow == .high_flow) "High Flow" else "Standard",
        .extruder_types = if (zs.printers.bambu(m.model)) |b| b.types else "Direct Drive",
        .default_volumes = if (zs.printers.bambu(m.model)) |b| b.volumes else "Standard",
        .variants = if (zs.printers.bambu(m.model)) |b| b.variants else "",
        .base_project = zs.printers.bambuProject(m.model) orelse "",
        .layer_height = app.settings.project.layer_height,
        .bbox = app.partBounds(),
        .object_name = if (title) |t| std.mem.span(t) else "zslice",
        .first_layer_height = app.settings.project.first_layer_height,
        .first_layer_time = firstLayerTime(app, st.print_time_s),
    }) catch return @intFromEnum(Status.out_of_memory);
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

/// The MQTT message (JSON) that starts the print of `file` (the name of the
/// uploaded .gcode.3mf) on a Bambu Lab printer. Publish it to
/// "device/<serial>/request" only after a fresh confirmation of the user
/// that the plate is clear. flags: 1 bed leveling, 2 the AMS, 4 a time
/// lapse, 8 the url form "ftp://<file>" (P1 and A1) in place of
/// "file:///sdcard/<file>" (X1). md5: the MD5 of the G-code
/// (zs_bambu_md5), or NULL. Free the bytes with zs_buffer_free.
export fn zs_bambu_start_message(file: ?[*:0]const u8, title: ?[*:0]const u8, md5: ?[*:0]const u8, flags: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const f = file orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const m = zs.bambu.startMessage(gpa, .{
        .file = std.mem.span(f),
        .title = if (title) |t| std.mem.span(t) else "zslice",
        .bed_leveling = flags & 1 != 0,
        .use_ams = flags & 2 != 0,
        .timelapse = flags & 4 != 0,
        .ftp_url = flags & 8 != 0,
        .md5 = if (md5) |m| std.mem.span(m) else "",
    }) catch return @intFromEnum(Status.out_of_memory);
    o.* = m.ptr;
    l.* = m.len;
    return ok;
}

/// zs_bambu_start_packet with the tray of each filament of the file
/// (zs_app_ams_mapping, `n` values): the ams_mapping and ams_mapping2 of
/// Bambu Studio. The printer loads each filament from its tray.
export fn zs_bambu_start_packet_trays(serial: ?[*:0]const u8, file: ?[*:0]const u8, title: ?[*:0]const u8, md5: ?[*:0]const u8, flags: c_int, trays: ?[*]const i32, n: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const sn = serial orelse return @intFromEnum(Status.invalid_argument);
    const f = file orelse return @intFromEnum(Status.invalid_argument);
    if (n > 64) return @intFromEnum(Status.invalid_argument);
    const msg = zs.bambu.startMessage(gpa, .{
        .file = std.mem.span(f),
        .title = if (title) |t| std.mem.span(t) else "zslice",
        .bed_leveling = flags & 1 != 0,
        .use_ams = flags & 2 != 0,
        .timelapse = flags & 4 != 0,
        .ftp_url = flags & 8 != 0,
        .md5 = if (md5) |m| std.mem.span(m) else "",
        .trays = if (trays) |t| t[0..n] else &.{},
    }) catch return @intFromEnum(Status.out_of_memory);
    defer gpa.free(msg);
    return bambuRequest(std.mem.span(sn), msg, out, out_len);
}

/// The MD5 of G-code, as 32 upper case hex digits and a 0, in out (33
/// bytes): the md5 of zs_bambu_start_message.
export fn zs_bambu_md5(gcode: ?[*]const u8, len: usize, out: ?*[33]u8) c_int {
    const g = gcode orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const h = zs.bambu.gcodeMd5(g[0..len]);
    @memcpy(o[0..32], &h);
    o[32] = 0;
    return ok;
}

/// The MQTT message that asks a Bambu Lab printer for its full status.
export fn zs_bambu_push_all_message() [*:0]const u8 {
    return zs.bambu.push_all_message;
}

/// A PUBLISH at QoS 0 of `payload` to `topic`. Free it with zs_buffer_free.
export fn zs_mqtt_publish_packet(topic: ?[*:0]const u8, payload: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const t = topic orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const body: []const u8 = if (payload) |p| p[0..len] else "";
    const pk = zs.mqtt.publishPacket(gpa, std.mem.span(t), body) catch |e| return switch (e) {
        error.TooBig => @intFromEnum(Status.invalid_argument),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
    };
    o.* = pk.ptr;
    l.* = pk.len;
    return ok;
}

/// A PUBLISH of `message` to device/<serial>/request.
fn bambuRequest(serial: []const u8, message: []const u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    if (serial.len == 0) return @intFromEnum(Status.invalid_argument);
    const topic = zs.bambu.requestTopic(gpa, serial) catch return @intFromEnum(Status.out_of_memory);
    defer gpa.free(topic);
    const pk = zs.mqtt.publishPacket(gpa, topic, message) catch |e| return switch (e) {
        error.TooBig => @intFromEnum(Status.invalid_argument),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
    };
    o.* = pk.ptr;
    l.* = pk.len;
    return ok;
}

/// The PUBLISH that asks the printer `serial` for its full status.
export fn zs_bambu_push_all_packet(serial: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    return bambuRequest(std.mem.span(serial orelse return @intFromEnum(Status.invalid_argument)), zs.bambu.push_all_message, out, out_len);
}

/// The PUBLISH that starts the print of `file` on the printer `serial`
/// (the message of zs_bambu_start_message, with its flags and md5). Send
/// it only after a fresh yes of the user that the plate is clear.
export fn zs_bambu_start_packet(serial: ?[*:0]const u8, file: ?[*:0]const u8, title: ?[*:0]const u8, md5: ?[*:0]const u8, flags: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const sn = serial orelse return @intFromEnum(Status.invalid_argument);
    var msg: ?[*]u8 = null;
    var n: usize = 0;
    const rc = zs_bambu_start_message(file, title, md5, flags, &msg, &n);
    if (rc != ok) return rc;
    defer gpa.free(msg.?[0..n]);
    return bambuRequest(std.mem.span(sn), msg.?[0..n], out, out_len);
}

/// The RTSP session of a Bambu Lab printer camera (src/rtsp.zig): the
/// shell writes the bytes of zs_rtsp_output to its TLS socket, and feeds
/// each byte that it reads. The frames come out in Annex B.
const Rtsp = zs.rtsp.Session;

export fn zs_rtsp_new(url: ?[*:0]const u8, user: ?[*:0]const u8, password: ?[*:0]const u8) ?*Rtsp {
    const u = url orelse return null;
    const r = gpa.create(Rtsp) catch return null;
    r.* = Rtsp.init(gpa, std.mem.span(u), if (user) |x| std.mem.span(x) else "", if (password) |x| std.mem.span(x) else "") catch {
        gpa.destroy(r);
        return null;
    };
    return r;
}

export fn zs_rtsp_free(r: ?*Rtsp) void {
    const x = r orelse return;
    x.deinit();
    gpa.destroy(x);
}

/// The bytes to write now (len 0: none), valid until the next call.
export fn zs_rtsp_output(r: ?*Rtsp, bytes: ?*?[*]const u8, len: ?*usize) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    const o = x.output();
    if (bytes) |p| p.* = o.ptr;
    if (len) |p| p.* = o.len;
    return ok;
}

export fn zs_rtsp_feed(r: ?*Rtsp, bytes: ?[*]const u8, len: usize) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    const b = bytes orelse return @intFromEnum(Status.invalid_argument);
    x.feed(b[0..len]) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

/// 1 and a frame (valid until the next call), or 0.
export fn zs_rtsp_next_frame(r: ?*Rtsp, data: ?*?[*]const u8, len: ?*usize, key: ?*c_int) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    const f = x.nextFrame() orelse return 0;
    if (data) |p| p.* = f.data.ptr;
    if (len) |p| p.* = f.data.len;
    if (key) |p| p.* = @intFromBool(f.key);
    return 1;
}

/// 0 connecting, 1 playing, -1 failed (zs_rtsp_message says why).
export fn zs_rtsp_state(r: ?*const Rtsp) c_int {
    const x = r orelse return -1;
    return @intFromEnum(x.state);
}

/// Why the session failed, for a person, or "".
export fn zs_rtsp_message(r: ?*const Rtsp) [*:0]const u8 {
    const x = r orelse return "";
    return zs.rtsp.failureText(x.failure).ptr;
}

/// A keep-alive request (send one each 30 s while playing).
export fn zs_rtsp_keepalive(r: ?*Rtsp) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    x.keepAlive() catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

/// A TEARDOWN request, to write before the socket closes.
export fn zs_rtsp_teardown(r: ?*Rtsp) c_int {
    const x = r orelse return @intFromEnum(Status.invalid_argument);
    x.teardown() catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

/// 1 if a change line of a history step (zs_history_step.changes) can be
/// undone alone (zs_app_history_revert): not the quality, and not a move,
/// turn, orientation, or scale of a part.
export fn zs_history_revertible(line: ?[*]const u8, len: usize) c_int {
    const l = line orelse return 0;
    return @intFromBool(zs.app.history.revertible(l[0..len]));
}

export fn zs_setting_count() usize {
    return app_mod.settings_info.len;
}

export fn zs_setting_get_info(index: usize, out: ?*SettingInfo) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (index >= app_mod.settings_info.len) return @intFromEnum(Status.out_of_range);
    const s = app_mod.settings_info[index];
    o.* = .{
        .name = s.name.ptr,
        .group = s.group.ptr,
        .section = s.section.ptr,
        .label = s.label.ptr,
        .doc = s.doc.ptr,
        .kind = @intFromEnum(s.kind),
        .multiline = @intFromBool(s.multiline),
        .choices = s.choices.ptr,
        .unit = s.unit.ptr,
        .default_value = s.default_value.ptr,
        .slider_min = s.slider_min,
        .slider_max = s.slider_max,
        .limit_min = s.limit_min,
        .limit_max = s.limit_max,
        .slider_step = s.slider_step,
        .per_layer = @intFromBool(s.per_layer),
        .per_part = @intFromBool(zs.settings.isPerPartSetting(s.name)),
        .nozzle = @intCast(s.nozzle),
    };
    return ok;
}

/// 1 if a part, or some layers, can have its own value of the setting
/// (settings.isPartSetting): the project and the filament settings, and
/// the accelerations of the printer (machine.outer_wall_accel and the
/// others).
export fn zs_setting_is_part(name: ?[*:0]const u8) c_int {
    const n = std.mem.span(name orelse return 0);
    return @intFromBool(zs.settings.isPartSetting(n));
}

/// The number of keys of a profile text of `group` that are old names of
/// settings that moved to another group (profile.movedKeys). The text
/// still loads. A shell that finds them in a saved text saves the groups
/// again after it loads them, so the values stay in their new group.
export fn zs_profile_moved(group: c_int, text: ?[*]const u8, len: usize) c_int {
    const g = groupOf(group) orelse return 0;
    const t = (text orelse return 0)[0..len];
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const n = zs.profile.movedKeys(arena.allocator(), g, t) catch return 0;
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

/// Writes the value as text with a NUL at the end. If `cap` is too small,
/// the text is cut. `out_len` (can be NULL) gets the full length without
/// the NUL.
export fn zs_app_setting_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.getSetting(n, &aw.writer) catch |e| return status(e);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap > 0) {
            const k = @min(text.len, cap - 1);
            @memcpy(b[0..k], text[0..k]);
            b[k] = 0;
        }
    }
    return ok;
}

export fn zs_app_setting_set(a: ?*App, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    app.setSetting(n, v) catch |e| return status(e);
    // A history step has no engine options. The thread count is an app
    // preference, so a change of it is no pending edit.
    if (!std.mem.eql(u8, n, "engine.threads")) noted(app, n, false);
    return ok;
}

export fn zs_app_slice(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.startSlice() catch |e| return status(e);
    return ok;
}

export fn zs_app_request_slice(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.requestSlice() catch |e| return status(e);
    return ok;
}

export fn zs_app_cancel(a: ?*App) void {
    const app = a orelse return;
    app.cancel();
}

/// The address of the cancel flag of the app (a byte: 1 stops the slice
/// that runs), or 0. On the web, the slice runs on the thread of the core
/// worker, so the worker cannot take a call while it slices; with a shared
/// memory, the page sets the byte with Atomics.store. A new slice sets it
/// back to 0.
export fn zs_app_cancel_address(a: ?*App) usize {
    const app = a orelse return 0;
    return @intFromPtr(&app.cancel_flag.raw);
}

export fn zs_app_stats(a: ?*const App, out: ?*Stats) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = cStats(app.result() orelse return @intFromEnum(Status.no_result));
    return ok;
}

/// A name for the G-code file of this slice, with no extension: the
/// model (`model`, its extension dropped), the plate (when `plate` > 0,
/// 1-based), the layer height, the material, the printer (not "generic"),
/// and the time, for example "3DBenchy_0.2mm_PLA_MK4_50m". Only letters,
/// digits, and ". + -" go in each part. The same name in each app.
export fn zs_app_gcode_name(a: ?*const App, model: ?[*:0]const u8, plate: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var text: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);
    var m: []const u8 = if (model) |x| std.mem.span(x) else "";
    for ([_][]const u8{ ".stl", ".3mf", ".obj", ".step", ".stp" }) |ext| {
        if (m.len > ext.len and std.ascii.endsWithIgnoreCase(m, ext)) m = m[0 .. m.len - ext.len];
    }
    const s = app.settings;
    if (!safePart(&w, m, 64, false)) w.writeAll("part") catch {};
    if (plate > 0) w.print("_plate{d}", .{plate}) catch {};
    if (s.project.layer_height > 0) w.print("_{d}mm", .{@round(s.project.layer_height * 1000) / 1000}) catch {};
    _ = safePart(&w, s.filament.material, 16, true);
    if (!std.ascii.eqlIgnoreCase(s.machine.name, "generic")) _ = safePart(&w, s.machine.name, 32, true);
    if (app.result()) |r| {
        const t = r.print_time_s;
        if (t > 0) {
            // The minutes first, then the hours: 2 h 59.6 min is "3h00m",
            // not "2h60m".
            const total: u64 = @max(1, @as(u64, @intFromFloat(@round(t / 60))));
            if (total >= 60) w.print("_{d}h{d:0>2}m", .{ total / 60, total % 60 }) catch {} else w.print("_{d}m", .{total}) catch {};
        }
    }
    return copyOut(w.buffered(), buf, cap, out_len);
}

/// Writes `t` with each run of other characters than letters, digits, and
/// ". + -" as one "-", no "-" at the ends, at most `max` bytes, after a
/// "_" when `sep`. Returns false when no character is left.
fn safePart(w: *std.Io.Writer, t: []const u8, max: usize, sep: bool) bool {
    var out: [64]u8 = undefined;
    var n: usize = 0;
    var dash = false;
    for (t) |ch| {
        const good = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '+' or ch == '-';
        if (!good or ch == '-') {
            dash = n > 0;
            continue;
        }
        if (n >= @min(max, out.len)) break;
        if (dash) {
            if (n + 1 >= @min(max, out.len)) break;
            out[n] = '-';
            n += 1;
            dash = false;
        }
        out[n] = ch;
        n += 1;
    }
    if (n == 0) return false;
    if (sep) w.writeAll("_") catch return false;
    w.writeAll(out[0..n]) catch return false;
    return true;
}

test "gcode name: the facts of the slice, safe for a file" {
    var o: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&o);
    try std.testing.expect(safePart(&w, " Prusa MK4/S ", 32, false));
    try std.testing.expect(safePart(&w, "Ender 3 V3", 5, true));
    try std.testing.expect(!safePart(&w, " // ", 32, true));
    try std.testing.expectEqualStrings("Prusa-MK4-S_Ender", w.buffered());
}

/// A picture of the parts of the plate as a PNG of w by h pixels (at most
/// 1024): from the front right and above, in the filament color, on a
/// clear background. It comes from the meshes, so a plate with no slice
/// has one too. A plate with no parts gives no_model. Free the bytes with
/// zs_buffer_free.
export fn zs_app_thumbnail_png(a: ?*const App, w: u32, h: u32, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    if (w == 0 or h == 0 or w > 1024 or h > 1024) return @intFromEnum(Status.out_of_range);
    const n = app.plate.parts.items.len;
    if (n == 0) return @intFromEnum(Status.no_model);
    const meshes = gpa.alloc(zs.Mesh, n) catch return @intFromEnum(Status.out_of_memory);
    var made: usize = 0;
    defer {
        for (meshes[0..made]) |*m| m.deinit(gpa);
        gpa.free(meshes);
    }
    for (meshes, 0..) |*m, i| {
        m.* = app.plate.partMesh(gpa, i) catch return @intFromEnum(Status.out_of_memory);
        made += 1;
    }
    var rgb = [3]u8{ 0xd0, 0xd0, 0xcc };
    const color = app.settings.filament.color;
    if (color.len == 7 and color[0] == '#') {
        for (0..3) |k| rgb[k] = std.fmt.parseInt(u8, color[1 + 2 * k ..][0..2], 16) catch rgb[k];
    }
    var img = zs.cpu_render.render(gpa, meshes, w, h, rgb) catch return @intFromEnum(Status.out_of_memory);
    defer img.deinit(gpa);
    const bytes = zs.cpu_render.png(gpa, img) catch return @intFromEnum(Status.out_of_memory);
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

test "thumbnail: a PNG of the parts, also with no slice" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    var out: ?[*]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(@intFromEnum(Status.no_model), zs_app_thumbnail_png(app, 64, 64, &out, &len));
    // A 10 mm cube as a binary STL.
    var stl: [84 + 12 * 50]u8 = @splat(0);
    std.mem.writeInt(u32, stl[80..84], 12, .little);
    const v = [_][3]f32{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 0, 0, 10 }, .{ 10, 0, 10 }, .{ 10, 10, 10 }, .{ 0, 10, 10 } };
    const f = [_][3]u8{ .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 1, 2, 6 }, .{ 1, 6, 5 }, .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 3, 0, 4 }, .{ 3, 4, 7 } };
    for (f, 0..) |t, k| {
        for (t, 0..) |vi, corner| for (0..3) |q| {
            std.mem.writeInt(u32, stl[84 + k * 50 + 12 + corner * 12 + q * 4 ..][0..4], @bitCast(v[vi][q]), .little);
        };
    }
    try std.testing.expectEqual(ok, zs_app_load_stl(app, "cube.stl", &stl, stl.len));
    try std.testing.expectEqual(ok, zs_app_thumbnail_png(app, 64, 48, &out, &len));
    defer gpa.free(out.?[0..len]);
    try std.testing.expect(len > 60);
    try std.testing.expectEqualSlices(u8, "\x89PNG", out.?[0..4]);
}

/// The number of islands of the last slice (see islands.zig).
export fn zs_app_island_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.islands().len;
}

/// Island i: its layer, its place (mm), and its area (mm²).
export fn zs_app_island_get(a: ?*const App, i: usize, layer: ?*usize, x: ?*f64, y: ?*f64, area: ?*f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const all = app.islands();
    if (i >= all.len) return @intFromEnum(Status.invalid_argument);
    const isl = all[i];
    if (layer) |p| p.* = isl.layer;
    if (x) |p| p.* = isl.x;
    if (y) |p| p.* = isl.y;
    if (area) |p| p.* = isl.area;
    return ok;
}

/// Adds a support mark: kind 0 grid, 1 tree, 2 bridge (a pad), 3 block.
export fn zs_app_mark_add(a: ?*App, x: f64, y: f64, z: f64, r: f64, kind: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (kind < 0 or kind > 3 or !(r > 0)) return @intFromEnum(Status.invalid_argument);
    app.addMark(.{ .x = x, .y = y, .z = z, .r = r, .kind = @enumFromInt(@as(u8, @intCast(kind))) }) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// Removes the marks near a place. Returns how many.
export fn zs_app_mark_remove_near(a: ?*App, x: f64, y: f64, z: f64, r: f64) usize {
    const app = a orelse return 0;
    const n = app.removeMarksNear(x, y, z, r);
    if (n > 0) noted(app, null, true);
    return n;
}

export fn zs_app_mark_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.marks.items.len;
}

/// The support mark at a place (in its disk, on a layer within dz of z),
/// or -1.
export fn zs_app_mark_at(a: ?*const App, x: f64, y: f64, z: f64, dz: f64) isize {
    const app = a orelse return -1;
    return if (app.markAt(x, y, z, dz)) |i| @intCast(i) else -1;
}

/// Mark i: its place, its radius, and its kind (enum zs_mark_kind).
export fn zs_app_mark_get(a: ?*const App, i: usize, x: ?*f64, y: ?*f64, z: ?*f64, r: ?*f64, kind: ?*c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.marks.items.len) return @intFromEnum(Status.out_of_range);
    const m = app.marks.items[i];
    if (x) |o| o.* = m.x;
    if (y) |o| o.* = m.y;
    if (z) |o| o.* = m.z;
    if (r) |o| o.* = m.r;
    if (kind) |o| o.* = @intFromEnum(m.kind);
    return ok;
}

/// Changes the kind and the radius of mark i.
export fn zs_app_mark_set(a: ?*App, i: usize, kind: c_int, r: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (kind < 0 or kind > 3 or !(r > 0)) return @intFromEnum(Status.invalid_argument);
    app.setMark(i, @enumFromInt(@as(u8, @intCast(kind))), r) catch return @intFromEnum(Status.out_of_range);
    noted(app, null, true);
    return ok;
}

export fn zs_app_mark_remove(a: ?*App, i: usize) void {
    const app = a orelse return;
    app.removeMark(i);
    noted(app, null, true);
}

export fn zs_app_marks_clear(a: ?*App) void {
    const app = a orelse return;
    app.clearMarks();
    noted(app, null, true);
}

/// The status of an error of the support areas.
fn areaStatus(e: zs.app.support_areas.Error) c_int {
    return switch (e) {
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        error.NoArea => @intFromEnum(Status.out_of_range),
        error.BadArea => @intFromEnum(Status.invalid_argument),
    };
}

/// The points of an area: n points of x, y, z (3 n values).
fn areaPoints(points: ?[*]const f64, n: usize) ?[]const [3]f64 {
    const p = points orelse return null;
    if (n < 3 or n > zs.app.support_areas.max_points) return null;
    return @as([*]const [3]f64, @ptrCast(p))[0..n];
}

/// Adds a support area (the support editor): a polygon of n points on the
/// surface of a part, x, y, z (mm) each, in `points` (3 n values). Kind 0
/// grid and 1 tree: support under the surface in the polygon that faces
/// down, in the z range z_lo to z_hi; 2 a pad; 3 block: no support there.
/// A z range with z_lo over z_hi (or NaN) comes from the z of the points.
/// Returns the index of the area, or -status. One history step. Slice
/// again after it.
export fn zs_app_support_area_add(a: ?*App, kind: c_int, points: ?[*]const f64, n: usize, z_lo: f64, z_hi: f64) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const pts = areaPoints(points, n) orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (!zs.app.support_areas.validKind(kind)) return -@as(isize, @intFromEnum(Status.invalid_argument));
    const i = app.areas.add(app.gpa, @enumFromInt(@as(u8, @intCast(kind))), pts, z_lo, z_hi) catch |e| return -@as(isize, areaStatus(e));
    noted(app, null, true);
    return @intCast(i);
}

/// The overhang of a part nearest to the bed point (x, y, z) mm, for the
/// support tool: the faces that face down and connect to the face nearest
/// to the point, within max_dist mm (see src/support_pick.zig). Writes its
/// outline (x, y, z each, at most cap points) to `points`, the count to
/// *n, and the z range. Returns the part, or -1 with no overhang there,
/// or -status. Give the outline to zs_app_support_area_add.
/// The pick data of the last meshes (support_pick.Prep), so a hover does
/// not make it again for each move of the pointer. A new mesh (a load, a
/// turn onto a side, a scale) has a new key and gets new data.
var pick_preps: [8]?zs.support_pick.Prep = @splat(null);
var pick_next: usize = 0;

fn pickPrep(mesh: *const zs.Mesh) std.mem.Allocator.Error!*const zs.support_pick.Prep {
    const key = zs.support_pick.Prep.keyOf(mesh);
    for (&pick_preps) |*e| if (e.*) |*pr| if (std.mem.eql(usize, &pr.key, &key)) return pr;
    const i = pick_next;
    pick_next = (pick_next + 1) % pick_preps.len;
    if (pick_preps[i]) |*old| old.deinit(gpa);
    pick_preps[i] = null;
    pick_preps[i] = try zs.support_pick.Prep.init(gpa, mesh);
    return &pick_preps[i].?;
}

export fn zs_app_support_pick(a: ?*App, x: f64, y: f64, z: f64, max_dist: f64, points: ?[*]f64, cap: usize, n: ?*usize, z_lo: ?*f64, z_hi: ?*f64) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const down = zs.support_pick.downFor(app.settings.project.support_angle);
    var best: ?zs.support_pick.Region = null;
    var best_part: isize = -1;
    var best_d = std.math.inf(f64);
    defer if (best) |*r| r.deinit(gpa);
    for (app.plate.parts.items, 0..) |*p, i| {
        const fp = p.footprint();
        if (x < fp[0] - max_dist or x > fp[2] + max_dist or y < fp[1] - max_dist or y > fp[3] + max_dist) continue;
        const pr = pickPrep(&p.mesh) catch return -@as(isize, @intFromEnum(Status.out_of_memory));
        var r = (zs.support_pick.pick(gpa, &p.mesh, pr, p.transform(), .{ x, y, z }, max_dist, down) catch return -@as(isize, @intFromEnum(Status.out_of_memory))) orelse continue;
        // The part with the region nearest to the point, by the middle of
        // its z range.
        const d = @abs((r.z_lo + r.z_hi) / 2 - z);
        if (d < best_d) {
            if (best) |*o| o.deinit(gpa);
            best = r;
            best_d = d;
            best_part = @intCast(i);
        } else r.deinit(gpa);
    }
    const r = best orelse return -1;
    const m = @min(r.points.len, cap);
    if (points) |out| for (r.points[0..m], 0..) |q, k| {
        out[3 * k] = q[0];
        out[3 * k + 1] = q[1];
        out[3 * k + 2] = q[2];
    };
    if (n) |o| o.* = m;
    if (z_lo) |o| o.* = r.z_lo;
    if (z_hi) |o| o.* = r.z_hi;
    return best_part;
}

/// Gives area i new points and a z range (as zs_app_support_area_add): a
/// drag of a point. For a drag, hold the slice of the plate (zs_set_changed_held)
/// and release it at the end.
export fn zs_app_support_area_set(a: ?*App, i: usize, points: ?[*]const f64, n: usize, z_lo: f64, z_hi: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const pts = areaPoints(points, n) orelse return @intFromEnum(Status.invalid_argument);
    app.areas.set(app.gpa, i, pts, z_lo, z_hi) catch |e| return areaStatus(e);
    noted(app, null, true);
    return ok;
}

/// Changes the kind of area i.
export fn zs_app_support_area_set_kind(a: ?*App, i: usize, kind: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (!zs.app.support_areas.validKind(kind)) return @intFromEnum(Status.invalid_argument);
    app.areas.setKind(i, @enumFromInt(@as(u8, @intCast(kind)))) catch |e| return areaStatus(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_support_area_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.areas.remove(app.gpa, i) catch |e| return areaStatus(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_support_area_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.areas.count();
}

/// Area i: its kind, its z range, and its points. *n gets the count of
/// points; `points` gets at most `cap` of them (3 values each). Any output
/// can be NULL.
export fn zs_app_support_area_get(a: ?*const App, i: usize, kind: ?*c_int, points: ?[*]f64, cap: usize, n: ?*usize, z_lo: ?*f64, z_hi: ?*f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.areas.count()) return @intFromEnum(Status.out_of_range);
    const area = app.areas.list.items[i];
    if (kind) |o| o.* = @intFromEnum(area.kind);
    if (n) |o| o.* = area.points.len;
    if (z_lo) |o| o.* = area.z_lo;
    if (z_hi) |o| o.* = area.z_hi;
    if (points) |o| {
        const out: [*][3]f64 = @ptrCast(o);
        const k = @min(cap, area.points.len);
        @memcpy(out[0..k], area.points[0..k]);
    }
    return ok;
}

// ---- The support trees (the support editor of tree support) ----

/// One node of the support trees of a part (zs_tree_node).
pub const TreeNode = extern struct {
    x: f64,
    y: f64,
    z: f64,
    r: f64,
    r_min: f64,
    down: i32,
    layer: u32,
    branch: u32,
    flags: u32,
};

const trees = app_mod.support_trees;

fn treeStatus(e: anyerror) c_int {
    return switch (e) {
        error.NoNode, error.NoPart => @intFromEnum(Status.out_of_range),
        error.NoRoom => @intFromEnum(Status.invalid_value),
        error.Busy => @intFromEnum(Status.busy),
        else => status(e),
    };
}

/// The nodes of the support trees of part `part`: the trees of the user
/// if they are edited, else the trees of the last slice. Writes at most
/// cap nodes to `out` (NULL: none) and returns the count of all nodes, or
/// -status (ZS_BUSY with no slice result).
export fn zs_app_support_tree_nodes(a: ?*App, part: usize, out: ?[*]TreeNode, cap: usize) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (part >= app.plate.count()) return -@as(isize, @intFromEnum(Status.out_of_range));
    const k = if (out != null) cap else 0;
    const buf = gpa.alloc(trees.NodeInfo, k) catch return -@as(isize, @intFromEnum(Status.out_of_memory));
    defer gpa.free(buf);
    const n = (trees.nodes(app, part, buf) catch return -@as(isize, @intFromEnum(Status.out_of_memory))) orelse return -@as(isize, @intFromEnum(Status.busy));
    if (out) |o| for (buf[0..@min(n, k)], 0..) |x, i| {
        o[i] = .{ .x = x.x, .y = x.y, .z = x.z, .r = x.r, .r_min = x.r_min, .down = x.down, .layer = x.layer, .branch = x.branch, .flags = x.flags };
    };
    return @intCast(n);
}

/// 1 if part `part` has support trees of the user, else 0.
export fn zs_app_support_tree_edited(a: ?*const App, part: usize) c_int {
    const app = a orelse return 0;
    if (part >= app.plate.count()) return 0;
    return @intFromBool(app.plate.parts.items[part].trees != null);
}

/// Moves node `node` of the trees of part `part` to (x, y) on the plate
/// (mm). *clamp (can be NULL) gets the rules that limited it (enum
/// zs_tree_clamp). One history step; hold the slice of the plate during
/// a drag.
export fn zs_app_support_tree_move_node(a: ?*App, part: usize, node: u32, x: f64, y: f64, clamp: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const bits = trees.moveNode(app, part, node, x, y) catch |e| return treeStatus(e);
    if (clamp) |o| o.* = bits;
    noted(app, null, true);
    return ok;
}

/// Sets the radius (mm) of node `node`: the width of its branch there.
export fn zs_app_support_tree_set_radius(a: ?*App, part: usize, node: u32, r: f64, clamp: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const bits = trees.setRadius(app, part, node, r) catch |e| return treeStatus(e);
    if (clamp) |o| o.* = bits;
    noted(app, null, true);
    return ok;
}

/// Moves the branch of node `node` by (dx, dy) mm: as far as the rules
/// allow.
export fn zs_app_support_tree_move_branch(a: ?*App, part: usize, node: u32, dx: f64, dy: f64, clamp: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const bits = trees.moveBranch(app, part, node, dx, dy) catch |e| return treeStatus(e);
    if (clamp) |o| o.* = bits;
    noted(app, null, true);
    return ok;
}

/// Deletes the branch of node `node` and the branches over it. Returns
/// the count of nodes that went, or -status.
export fn zs_app_support_tree_delete_branch(a: ?*App, part: usize, node: u32) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const n = trees.deleteBranch(app, part, node) catch |e| return -@as(isize, treeStatus(e));
    noted(app, null, true);
    return @intCast(n);
}

/// Adds a branch from the bed point (fx, fy) to the point (tx, ty, tz) of
/// the part that needs support (mm, on the plate). Returns the tip node
/// of the new branch, or -status (ZS_INVALID_VALUE: no room for a branch
/// there).
export fn zs_app_support_tree_add_branch(a: ?*App, part: usize, fx: f64, fy: f64, tx: f64, ty: f64, tz: f64, clamp: ?*u32) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const got = trees.addBranch(app, part, fx, fy, tx, ty, tz) catch |e| return -@as(isize, treeStatus(e));
    if (clamp) |o| o.* = got.clamp;
    noted(app, null, true);
    return @intCast(got.tip);
}

/// The planned trees again for part `part`. Returns 1 if it had trees of
/// the user, else 0.
export fn zs_app_support_tree_reset(a: ?*App, part: usize) c_int {
    const app = a orelse return 0;
    if (!trees.reset(app, part)) return 0;
    noted(app, null, true);
    return 1;
}

/// The note of the last drop of the trees of the user (a turn or a scale
/// of the part, or other layers): the app planned them again. Copies it
/// to buf (at most cap bytes with a 0 at the end) and returns its length,
/// or 0 with no note. The note goes after the call.
export fn zs_app_support_tree_note(a: ?*App, buf: ?[*]u8, cap: usize) usize {
    const app = a orelse return 0;
    trees.check(app);
    const t = trees.takeNote(app) orelse return 0;
    if (buf) |b| if (cap > 0) {
        const k = @min(t.len, cap - 1);
        @memcpy(b[0..k], t[0..k]);
        b[k] = 0;
    };
    return t.len;
}

export fn zs_app_write_3mf(a: ?*App, out: ?*?[*]const u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const b = app.write3mf() catch |e| return status(e);
    o.* = b.ptr;
    l.* = b.len;
    return ok;
}

/// The G-code of the last slice. The bytes stay valid until the next
/// slice, the next model, or zs_app_free. A draft slice has no G-code
/// (see zs_app_set_draft).
export fn zs_app_gcode(a: ?*const App, out: ?*?[*]const u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const g = app.exactGcode() orelse return @intFromEnum(Status.no_result);
    o.* = g.ptr;
    l.* = g.len;
    return ok;
}

/// An edit of the user on a line of the last slice (the segment editor):
/// kind 0 deletes the line, kind 1 prints it with `value` times its plastic
/// (0.1 to 3). An edit of the same line replaces the one before. The edit
/// stays, and applies to each new slice that makes the same line again.
/// Slice again after it (zs_app_request_slice). One history step.
export fn zs_app_edit_add(a: ?*App, path: usize, kind: c_int, value: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = app.allToolpaths() orelse return @intFromEnum(Status.no_result);
    if (path >= t.path_key.items.len) return @intFromEnum(Status.out_of_range);
    const k: zs.app.edits_mod.Kind = switch (kind) {
        0 => .delete,
        1 => .flow,
        else => return @intFromEnum(Status.invalid_argument),
    };
    const layer = t.layerOfPath(path) orelse 0;
    app.edits.put(app.gpa, .{ .key = t.path_key.items[path], .kind = k, .value = @floatCast(value), .layer = @intCast(layer) }) catch return @intFromEnum(Status.out_of_memory);
    noted(app, null, true);
    return ok;
}

/// A drop of plastic of diameter d (mm, at least the line width) at (x, y)
/// mm on layer `layer` of the last slice, to fill a small gap: a short
/// closed loop at the end of the layer. A drop at the same place replaces
/// the one before. Slice again after it. One history step.
export fn zs_app_edit_add_dot(a: ?*App, layer: usize, x: f64, y: f64, d: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = app.allToolpaths() orelse return @intFromEnum(Status.no_result);
    if (layer >= t.layer_z.items.len) return @intFromEnum(Status.out_of_range);
    const z = t.layer_z.items[layer];
    const xf: f32 = @floatCast(x);
    const yf: f32 = @floatCast(y);
    app.edits.put(app.gpa, .{ .key = zs.app.edits_mod.Edits.dotKey(z, xf, yf), .kind = .dot, .value = @floatCast(@max(d, 0.2)), .layer = @intCast(layer), .x = xf, .y = yf, .z = z }) catch return @intFromEnum(Status.out_of_memory);
    noted(app, null, true);
    return ok;
}

/// The key of line `path` of the last slice for an edit (0 if there is no
/// slice). A shell reads it when the user selects the line, and adds the
/// edit with zs_app_edit_add_key, also while a new slice runs.
export fn zs_app_path_key(a: ?*const App, path: usize) u64 {
    const app = a orelse return 0;
    const t = app.allToolpaths() orelse return 0;
    if (path >= t.path_key.items.len) return 0;
    return t.path_key.items[path];
}

/// zs_app_edit_add with the key of the line (zs_app_path_key) and its
/// layer: it works while a slice runs.
export fn zs_app_edit_add_key(a: ?*App, key: u64, layer: usize, kind: c_int, value: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (key == 0) return @intFromEnum(Status.invalid_argument);
    const k: zs.app.edits_mod.Kind = switch (kind) {
        0 => .delete,
        1 => .flow,
        else => return @intFromEnum(Status.invalid_argument),
    };
    app.edits.put(app.gpa, .{ .key = key, .kind = k, .value = @floatCast(value), .layer = @intCast(layer) }) catch return @intFromEnum(Status.out_of_memory);
    noted(app, null, true);
    return ok;
}

/// zs_app_edit_add_dot with the z of the layer (mm): it works while a
/// slice runs. The shell reads the z when it shows the layer.
export fn zs_app_edit_add_dot_z(a: ?*App, layer: usize, z: f64, x: f64, y: f64, d: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const zf: f32 = @floatCast(z);
    const xf: f32 = @floatCast(x);
    const yf: f32 = @floatCast(y);
    app.edits.put(app.gpa, .{ .key = zs.app.edits_mod.Edits.dotKey(zf, xf, yf), .kind = .dot, .value = @floatCast(@max(d, 0.2)), .layer = @intCast(layer), .x = xf, .y = yf, .z = zf }) catch return @intFromEnum(Status.out_of_memory);
    noted(app, null, true);
    return ok;
}

/// The layer of path `path` of the last slice, or -1.
/// The run of a path: the first and the last path of the extrusion it is
/// in, from one retraction to the next, on its layer (Shift+click selects
/// it). Not ok when the slice has no such path.
export fn zs_app_path_run(a: ?*const App, path: usize, first: ?*usize, last: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    // The retractions of the slice (the simulated paths have the same
    // paths, in the same order).
    if (app.getState() != .done) return @intFromEnum(Status.no_result);
    const r = app.toolpaths.runOf(path) orelse return @intFromEnum(Status.invalid_argument);
    if (first) |f| f.* = r[0];
    if (last) |l| l.* = r[1];
    return ok;
}

export fn zs_app_path_layer(a: ?*const App, path: usize) isize {
    const app = a orelse return -1;
    const l = app.layerOfPath(path) orelse return -1;
    return @intCast(l);
}

/// The filament (from 1) that prints path `path` of the last slice, or 0
/// for no such path.
export fn zs_app_path_filament(a: ?*const App, path: usize) u32 {
    const app = a orelse return 0;
    const t = app.allToolpaths() orelse return 0;
    if (path >= t.path_tool.items.len) return 0;
    return @as(u32, t.path_tool.items[path]) + 1;
}

/// The count of the edits of the user.
export fn zs_app_edit_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.edits.list.items.len;
}

/// Edit i: its kind, its value, the layer of its line when it was made,
/// and 1 in *applied if the last slice found its line (0: the line is not
/// there now; the edit waits). Any output can be NULL.
export fn zs_app_edit_get(a: ?*const App, i: usize, kind: ?*c_int, value: ?*f64, layer: ?*usize, applied: ?*c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.edits.list.items.len) return @intFromEnum(Status.out_of_range);
    const e = &app.edits.list.items[i];
    if (kind) |o| o.* = @intFromEnum(e.kind);
    if (value) |o| o.* = e.value;
    if (layer) |o| o.* = e.layer;
    if (applied) |o| o.* = @intFromBool(e.applied.load(.acquire));
    return ok;
}

/// Removes edit i. Slice again after it. One history step.
export fn zs_app_edit_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.edits.list.items.len) return @intFromEnum(Status.out_of_range);
    app.edits.remove(i);
    noted(app, null, true);
    return ok;
}

/// A debug print: the G-code of the layers lo to hi - 1 of the last slice
/// alone, lowered so that layer lo prints on the bed ("print this layer":
/// hi = lo + 1). Each layer keeps its height, lines, and speeds. Free the
/// bytes with zs_buffer_free.
export fn zs_app_debug_gcode(a: ?*App, lo: usize, hi: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const bytes = app.debugGcode(gpa, lo, hi) catch |e| return switch (e) {
        error.NoResult => @intFromEnum(Status.no_result),
        error.OutOfMemory, error.WriteFailed => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_argument),
    };
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

export fn zs_app_layer_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.layerCount();
}

export fn zs_app_part_bounds(a: ?*const App, out: ?*[4]f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = app.partBounds() orelse return @intFromEnum(Status.no_result);
    return ok;
}

pub const LayerPaths = extern struct {
    points: [*]const f32,
    path_ends: [*]const u32,
    path_features: [*]const u8,
    path_closed: [*]const u8,
    path_count: usize,
    outline_points: [*]const f32,
    outline_ends: [*]const u32,
    outline_count: usize,
    z: f32,
    height: f32,
    width: f32,
    owner: ?*anyopaque,
};

export fn zs_app_layer_paths(a: ?*const App, layer: usize, out: ?*LayerPaths) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const lp = gpa.create(app_mod.LayerPaths) catch |e| return status(e);
    lp.* = app.layerPaths(gpa, layer) catch |e| {
        gpa.destroy(lp);
        return status(e);
    };
    o.* = .{
        .points = lp.points.ptr,
        .path_ends = lp.ends.ptr,
        .path_features = lp.features.ptr,
        .path_closed = lp.closed.ptr,
        .path_count = lp.ends.len,
        .outline_points = lp.outline_points.ptr,
        .outline_ends = lp.outline_ends.ptr,
        .outline_count = lp.outline_ends.len,
        .z = lp.z,
        .height = lp.height,
        .width = lp.width,
        .owner = lp,
    };
    return ok;
}

export fn zs_layer_paths_free(paths: ?*LayerPaths) void {
    const p = paths orelse return;
    const owner = p.owner orelse return;
    const lp: *app_mod.LayerPaths = @ptrCast(@alignCast(owner));
    lp.deinit();
    gpa.destroy(lp);
    p.owner = null;
}

pub const Toolpaths = extern struct {
    points: [*]const f32,
    path_ends: [*]const u32,
    path_features: [*]const u8,
    path_closed: [*]const u8,
    path_area: [*]const f32,
    path_end_time: [*]const f32,
    path_count: usize,
    layer_ends: [*]const u32,
    layer_z: [*]const f32,
    layer_height: [*]const f32,
    layer_width: [*]const f32,
    layer_count: usize,
    path_start_time: [*]const f32,
    path_retract: [*]const u8,
    z_hop: f32,
    layer_slowed: [*]const u8,
    path_z_start: [*]const u32,
    point_z: [*]const f32,
    point_area: [*]const f32,
    path_height: [*]const f32,
};

/// The paths of all layers, for a 3D view. The arrays stay valid until the
/// next slice, the next model, or zs_app_free.
export fn zs_app_toolpaths(a: ?*const App, out: ?*Toolpaths) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const t = app.allToolpaths() orelse return @intFromEnum(Status.no_result);
    o.* = .{
        .points = t.points.items.ptr,
        .path_ends = t.path_ends.items.ptr,
        .path_features = t.path_features.items.ptr,
        .path_closed = t.path_closed.items.ptr,
        .path_area = t.path_area.items.ptr,
        .path_end_time = t.path_end_time.items.ptr,
        .path_count = t.path_ends.items.len,
        .layer_ends = t.layer_ends.items.ptr,
        .layer_z = t.layer_z.items.ptr,
        .layer_height = t.layer_height.items.ptr,
        .layer_width = t.layer_width.items.ptr,
        .layer_count = t.layer_ends.items.len,
        .path_start_time = t.path_start_time.items.ptr,
        .path_retract = t.path_retract.items.ptr,
        .z_hop = t.z_hop,
        .layer_slowed = t.layer_slowed.items.ptr,
        .path_z_start = t.path_z_start.items.ptr,
        .point_z = t.point_z.items.ptr,
        .point_area = t.point_area.items.ptr,
        .path_height = t.path_height.items.ptr,
    };
    return ok;
}

/// The numbers of a simulated print (see zs_print_sim_stats).
pub const PrintSimStats = extern struct {
    masses: usize,
    soft_masses: usize,
    moved: usize,
    moved_paths: usize,
    max_move: f32,
    mass: f64,
    peak_soft: usize,
    steps: usize,
    /// The masses that failed: they set more than 1.5 mm under their
    /// place, so the layers above them have nothing under them there.
    failed: usize,
    /// The first layer (from 0) with a failed mass, or -1.
    first_failed_layer: isize,
    /// The largest drop of a mass under its place, mm.
    max_drop: f32,
    /// 1 if the simulation has data for the plastic of the filament, 0 if
    /// it uses the nearest plastic with data (`material`).
    material_exact: c_int,
    /// The plastic of the simulation ("PLA", "ABS", "PETG"), with a 0.
    material: [16]u8,
};

fn simStats(app: *const App, st: zs.print_sim.Stats) PrintSimStats {
    const m = app.simulatedMaterial();
    var name = [_]u8{0} ** 16;
    @memcpy(name[0..@min(m.name.len, 15)], m.name[0..@min(m.name.len, 15)]);
    return .{
        .masses = st.masses,
        .soft_masses = st.soft_masses,
        .moved = st.moved,
        .moved_paths = st.moved_paths,
        .max_move = st.max_move,
        .mass = st.mass,
        .peak_soft = st.peak_soft,
        .steps = st.steps,
        .failed = st.failed,
        .first_failed_layer = if (st.first_failed_layer == zs.print_sim.none) -1 else @intCast(st.first_failed_layer),
        .max_drop = st.max_drop,
        .material_exact = @intFromBool(m.exact),
        .material = name,
    };
}

/// Simulates the plastic of the last slice, and shows the result in
/// zs_app_toolpaths (see App.simulatePrint).
export fn zs_app_simulate_print(a: ?*App, out: ?*PrintSimStats) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const st = app.simulatePrint() catch |e| return status(e);
    if (out) |o| o.* = simStats(app, st);
    return ok;
}

/// Simulate the print after each slice (on = 1), on the thread of the
/// slice: ZS_EVENT_SIMULATED tells when it is ready, and
/// zs_app_show_simulated(app, 1) or zs_app_sim_adopt shows it. A change
/// stops it.
export fn zs_app_set_auto_simulate(a: ?*App, on: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.auto_simulate = on != 0;
    return ok;
}

/// Simulates the print of the last slice on a worker thread, with no
/// wait: ZS_EVENT_SIMULATED tells when it is ready (see
/// App.requestSimulation). ZS_NO_RESULT with no slice.
export fn zs_app_sim_request(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.requestSimulation() catch |e| return status(e);
    return ok;
}

/// Runs the printability check after each slice (on = 1), on the thread
/// of the slice after ZS_EVENT_SLICED: zs_app_checks gives ZS_BUSY until
/// ZS_EVENT_CHECKED, then returns the check at once.
export fn zs_app_set_auto_checks(a: ?*App, on: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.auto_checks = on != 0;
    return ok;
}

/// Shows the simulated print of the thread of the slice that waits.
/// Returns 1 if one waited, else 0.
export fn zs_app_sim_adopt(a: ?*App) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.adoptSimulation());
}

/// Starts a simulation of the last slice that runs in pieces
/// (zs_app_sim_advance), for a shell with no threads. ZS_NO_RESULT with no
/// slice.
export fn zs_app_sim_begin(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.beginSimulation() catch |e| return status(e);
    return ok;
}

/// Runs a piece of the simulation of zs_app_sim_begin: up to `paths`
/// paths. *done is 1 when it is done: then zs_app_toolpaths gives the
/// plastic as it set. ZS_NO_RESULT if no simulation runs.
export fn zs_app_sim_advance(a: ?*App, paths: usize, done: ?*c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const d = app.advanceSimulation(paths) catch |e| return status(e);
    if (done) |p| p.* = @intFromBool(d);
    return ok;
}

/// The share of the simulation of zs_app_sim_begin that ran, 0 to 1.
export fn zs_app_sim_progress(a: ?*const App) f64 {
    const app = a orelse return 0;
    return app.simulationProgress();
}

/// 1 if the simulation of the slice runs on the worker now, with the
/// share that ran in `fraction` (0 to 1); else 0.
export fn zs_app_sim_work(a: ?*const App, fraction: ?*f64) c_int {
    const app = a orelse return 0;
    const f = app.simulationWork() orelse return 0;
    if (fraction) |out| out.* = f;
    return 1;
}

/// The numbers of the last simulated print, with no new simulation.
/// ZS_NO_RESULT if there is no simulation of the last slice.
export fn zs_app_sim_stats(a: ?*const App, out: ?*PrintSimStats) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const r = app.sim orelse return @intFromEnum(Status.no_result);
    if (out) |o| o.* = simStats(app, r.stats);
    return ok;
}

/// The outcome of one layer of the last simulated print: the largest
/// drop of its plastic under its place (mm), and its failed masses.
/// ZS_NO_RESULT with no simulation, ZS_INVALID_ARGUMENT for a layer out
/// of range.
export fn zs_app_sim_layer(a: ?*const App, layer: usize, max_drop: ?*f32, failed: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const layers = app.simulatedLayers() orelse return @intFromEnum(Status.no_result);
    if (layer >= layers.len) return @intFromEnum(Status.invalid_argument);
    if (max_drop) |p| p.* = layers[layer].max_drop;
    if (failed) |p| p.* = layers[layer].failed;
    return ok;
}

/// Shows the simulated print (on = 1) or the slice (on = 0) in
/// zs_app_toolpaths.
export fn zs_app_show_simulated(a: ?*App, on: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.showSimulated(on != 0) catch |e| return status(e);
    return ok;
}

pub const Inspect = extern struct {
    feature: c_int,
    layer: usize,
    path: usize,
    z: f64,
    height: f64,
    line_width: f64,
    bead_width: f64,
    length: f64,
    planned_speed: f64,
    speed: f64,
    flow: f64,
    start_time: f64,
    end_time: f64,
    title: [*:0]const u8,
    explain: [*:0]const u8,
    settings: [*:0]const u8,
    why_planned: [*:0]const u8,
    why_real: [*:0]const u8,
    why_flow: [*:0]const u8,
    slow_reason: c_int,
    /// The sentence of slow_reason, or "".
    slow_text: [*:0]const u8,
    /// The part fan of the line, 0 (off) to 1 (full).
    fan: f64,
    /// The print time of the layer of the line, s.
    layer_time: f64,
    /// The flow limit of the filament, mm^3/s (filament.max_flow).
    max_flow: f64,
    /// 1 if the flow limit, not the machine, sets the planned speed.
    flow_limited: c_int,
    /// For a support line: the layer and the feature of the part line
    /// that it holds up. ZS_NO_PATH and -1: none.
    holds_layer: u32,
    holds_feature: c_int,
    /// The nozzle of the line on a printer with two nozzles: 1 the main
    /// nozzle, 2 the second. 0: a printer with one nozzle.
    nozzle: c_int,
    /// The nozzle of the line and its speed limits in words, or "".
    nozzle_text: [*:0]const u8,
};

/// 1 if the check of the last slice has run, so zs_app_checks returns at
/// once; else 0.
export fn zs_app_checks_ready(a: ?*const App) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.checksReady());
}

/// The printability check of the last slice: the issues, the worst
/// first, and the text that they point into. Valid until the next slice.
export fn zs_app_checks(a: ?*App, issues: ?*?[*]const zs.app.checks_mod.Issue, n: ?*usize, text: ?*?[*]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const r = app.checks() catch |e| return switch (e) {
        error.NoResult => @intFromEnum(Status.no_result),
        error.Pending => @intFromEnum(Status.busy),
        else => status(e),
    };
    if (issues) |o| o.* = r.issues.ptr;
    if (n) |o| o.* = r.issues.len;
    if (text) |o| o.* = r.text.ptr;
    return ok;
}

/// The number of built-in profiles of a group (enum zs_group).
export fn zs_builtin_profile_count(group: c_int) usize {
    var n: usize = 0;
    for (zs.profile.builtins) |b| {
        if (@intFromEnum(b.group) == group) n += 1;
    }
    return n;
}

/// The name of built-in profile i of a group, or null.
export fn zs_builtin_profile_name(group: c_int, i: usize) ?[*:0]const u8 {
    var k: usize = 0;
    for (zs.profile.builtins) |b| {
        if (@intFromEnum(b.group) != group) continue;
        if (k == i) return b.name.ptr;
        k += 1;
    }
    return null;
}

/// The main points of built-in quality profile `name` in a short line for a
/// menu ("0.1 mm layers · 3 walls · slower walls · ironed tops"), as
/// zs.profile.qualitySummary. Writes at most cap - 1 bytes and a 0 to buf;
/// out_len gets the full length. An empty text for an unknown name.
export fn zs_quality_summary(name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const n = name orelse return @intFromEnum(Status.invalid_argument);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    zs.profile.qualitySummary(gpa, std.mem.span(n), &out.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = out.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The gaps of a layer of the last slice (see App.layerGaps). The arrays
/// stay valid until the next call for another layer, or the next slice.
export fn zs_app_layer_gaps(a: ?*App, layer: usize, gaps: ?*?[*]const zs.gaps.Gap, n_gaps: ?*usize, runs: ?*?[*]const zs.gaps.Run, n_runs: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const r = app.layerGaps(layer) catch |e| return switch (e) {
        error.InvalidArgument => @intFromEnum(Status.invalid_argument),
        error.NoResult => @intFromEnum(Status.no_result),
        else => status(e),
    };
    if (gaps) |o| o.* = r.gaps.ptr;
    if (n_gaps) |o| o.* = r.gaps.len;
    if (runs) |o| o.* = r.runs.ptr;
    if (n_runs) |o| o.* = r.runs.len;
    return ok;
}

/// The gap of layer `layer` at x, y (mm), or the nearest one within 0.3
/// mm, or -1. The cell size of the gaps of the layer goes to `cell`.
export fn zs_app_gap_at(a: ?*App, layer: usize, x: f64, y: f64, cell: ?*f64) i64 {
    const app = a orelse return -1;
    const r = app.layerGaps(layer) catch return -1;
    if (cell) |out| out.* = r.cell;
    return if (r.at(x, y, 0.3)) |i| @intCast(i) else -1;
}

/// The size of the cells of the gaps of a layer (mm), or 0.
export fn zs_app_gap_cell(a: ?*App, layer: usize) f64 {
    const app = a orelse return 0;
    const r = app.layerGaps(layer) catch return 0;
    return r.cell;
}

/// A setting that can close a gap: its name, the value to try, and why.
/// The strings are not NUL-terminated.
pub const GapStep = extern struct {
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
    why: [*]const u8,
    why_len: usize,
};

/// The settings that can close gap `index` of layer `layer`, the best
/// first, at most `cap` of them in `out`. `n` gets their number. Valid
/// until the next call or slice.
export fn zs_app_gap_advice(a: ?*App, layer: usize, index: usize, out: ?[*]GapStep, cap: usize, n: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const steps = app.gapAdvice(layer, index) catch |e| return switch (e) {
        error.InvalidArgument => @intFromEnum(Status.invalid_argument),
        error.NoResult => @intFromEnum(Status.no_result),
        else => status(e),
    };
    if (n) |o| o.* = steps.len;
    if (out) |o| for (steps[0..@min(cap, steps.len)], 0..) |st, i| {
        o[i] = .{ .name = st.name.ptr, .name_len = st.name.len, .value = st.value.ptr, .value_len = st.value.len, .why = st.why.ptr, .why_len = st.why.len };
    };
    return ok;
}

/// A plain-text report of a line, for "Copy for AI". Valid until the next
/// call or inspection.
export fn zs_app_line_report(a: ?*App, path: usize, gcode_file: ?[*:0]const u8, out: ?*?[*]const u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const file = if (gcode_file) |f| std.mem.span(f) else "(not saved)";
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const r = app.lineReport(path, file) catch |e| return status(e);
    o.* = r.ptr;
    l.* = r.len;
    return ok;
}

export fn zs_app_inspect(a: ?*App, path: usize, out: ?*Inspect) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const i = app.inspect(path) catch |e| return status(e);
    o.* = .{
        .feature = @intFromEnum(i.feature),
        .layer = i.layer,
        .path = i.path,
        .z = i.z,
        .height = i.height,
        .line_width = i.line_width,
        .bead_width = i.bead_width,
        .length = i.length,
        .planned_speed = i.planned_speed,
        .speed = i.speed,
        .flow = i.flow,
        .start_time = i.start_time,
        .end_time = i.end_time,
        .title = i.title.ptr,
        .explain = i.explain.ptr,
        .why_planned = i.why_planned.ptr,
        .why_real = i.why_real.ptr,
        .why_flow = i.why_flow.ptr,
        .slow_reason = i.slow_reason,
        .settings = i.settings.ptr,
        .slow_text = app_mod.inspect_picks.slowText(i.slow_reason).ptr,
        .fan = i.fan,
        .layer_time = i.layer_time,
        .max_flow = i.max_flow,
        .flow_limited = @intFromBool(i.flow_limited),
        .holds_layer = if (i.holds) |h| @intCast(h.layer) else 0xffffffff,
        .holds_feature = if (i.holds) |h| @intFromEnum(h.feature) else -1,
        .nozzle = i.nozzle,
        .nozzle_text = i.nozzle_text.ptr,
    };
    return ok;
}

pub const Pick = extern struct {
    name: [*:0]const u8,
    why: [*:0]const u8,
};

/// The settings that matter most for path `path`, best first, at most max
/// (see src/app/inspect_picks.zig). The strings are static.
export fn zs_app_inspect_picks(a: ?*App, path: usize, out: ?[*]Pick, max: usize, n: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    // A separate arena: the strings of the last zs_app_inspect stay valid.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const i = app.inspectIn(arena.allocator(), path) catch |e| return status(e);
    const Ctx = struct {
        app: *const App,
        z: f64,
        fn changed(ctx: *const anyopaque, name: []const u8) u8 {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (self.app.hasOverrideAt(self.z, name)) return 1;
            const src = self.app.source(null, name);
            return if (src.level == .print or src.level == .part) 2 else 0;
        }
    };
    const ctx: Ctx = .{ .app = app, .z = i.z };
    var buf: [32]app_mod.inspect_picks.Pick = undefined;
    const count = app_mod.inspect_picks.picks(.{
        .feature = @intFromEnum(i.feature),
        .layer = i.layer,
        .slow_reason = i.slow_reason,
        .settings = i.settings,
        .ctx = &ctx,
        .changed = Ctx.changed,
    }, buf[0..@min(max, buf.len)]);
    for (buf[0..count], 0..) |p, k| o[k] = .{ .name = p.name.ptr, .why = p.why.ptr };
    if (n) |cnt| cnt.* = count;
    return ok;
}

pub const SettingEffect = extern struct {
    features: u32,
    first_layer_only: c_int,
    note: [*:0]const u8,
};

/// The speed in mm/s of a speed ratio setting with the value `value`, and
/// the other settings of the app.
export fn zs_app_ratio_speed(a: ?*const App, name: ?[*:0]const u8, value: ?[*:0]const u8, out: ?*f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = app_mod.ratioSpeed(app.settings, n, v) orelse return @intFromEnum(Status.unknown_setting);
    return ok;
}

export fn zs_setting_get_effect(name: ?[*:0]const u8, out: ?*SettingEffect) c_int {
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const e = app_mod.settingEffect(n);
    o.* = .{ .features = e.features, .first_layer_only = @intFromBool(e.first_layer_only), .note = e.note.ptr };
    return ok;
}

pub const FeatureStats = extern struct {
    time_s: f64,
    length_mm: f64,
    volume_mm3: f64,
    paths: usize,
};

export fn zs_app_feature_stats(a: ?*const App, out: ?[*]FeatureStats) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const stats = app.featureStats() orelse return @intFromEnum(Status.no_result);
    for (stats, 0..) |s, i| o[i] = .{ .time_s = s.time, .length_mm = s.length, .volume_mm3 = s.volume, .paths = s.paths };
    return ok;
}

/// Changes a setting for the layers with a top z from z_min to z_max (mm).
export fn zs_app_override_set(a: ?*App, z_min: f64, z_max: f64, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    app.setOverride(z_min, z_max, n, v) catch |e| return switch (e) {
        error.NotPerLayer => @intFromEnum(Status.invalid_argument),
        else => status(e),
    };
    // The changes for some layers are in the 3MF file of the plate.
    noted(app, n, true);
    return ok;
}

/// The number of overrides, and override i: its range, setting, and value.
/// The strings are valid until the next change of the overrides.
export fn zs_app_override_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.overrides.items.len;
}

pub const Override = extern struct {
    z_min: f64,
    z_max: f64,
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
};

export fn zs_app_override_get(a: ?*const App, i: usize, out: ?*Override) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.overrides.items.len) return @intFromEnum(Status.invalid_argument);
    const v = app.overrides.items[i];
    o.* = .{ .z_min = v.z_min, .z_max = v.z_max, .name = v.name.ptr, .name_len = v.name.len, .value = v.value.ptr, .value_len = v.value.len };
    return ok;
}

/// Removes the override of a setting for exactly the range z_min..z_max.
/// Returns 1 if there was one.
export fn zs_app_override_remove(a: ?*App, z_min: f64, z_max: f64, name: ?[*:0]const u8) c_int {
    const app = a orelse return 0;
    const n = std.mem.span(name orelse return 0);
    const removed = app.removeOverride(z_min, z_max, n);
    if (removed) noted(app, n, true);
    return @intFromBool(removed);
}

/// Layer profiles: a name for a layer range. The overrides with the same
/// range are its changes.
export fn zs_app_profile_set(a: ?*App, z_min: f64, z_max: f64, name: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.setProfile(z_min, z_max, std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_profile_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.profiles.items.len;
}

pub const Profile = extern struct {
    z_min: f64,
    z_max: f64,
    name: [*]const u8,
    name_len: usize,
};

export fn zs_app_profile_get(a: ?*const App, i: usize, out: ?*Profile) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.profiles.items.len) return @intFromEnum(Status.invalid_argument);
    const p = app.profiles.items[i];
    o.* = .{ .z_min = p.z_min, .z_max = p.z_max, .name = p.name.ptr, .name_len = p.name.len };
    return ok;
}

/// Removes a layer range: its name and all its overrides. Returns the
/// number of overrides removed.
export fn zs_app_profile_remove(a: ?*App, z_min: f64, z_max: f64) usize {
    const app = a orelse return 0;
    defer noted(app, null, true);
    return app.removeProfile(z_min, z_max);
}

/// Removes the overrides of a setting that cover z. Returns how many.
export fn zs_app_override_clear_at(a: ?*App, z: f64, name: ?[*:0]const u8) usize {
    const app = a orelse return 0;
    const n = std.mem.span(name orelse return 0);
    const k = app.clearOverridesAt(z, n);
    if (k > 0) noted(app, n, true);
    return k;
}

export fn zs_app_override_at(a: ?*const App, z: f64, name: ?[*:0]const u8) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.hasOverrideAt(z, std.mem.span(name orelse return 0)));
}

/// The value of a setting for the layers at z, with the overrides. The
/// same buffer rules as zs_app_setting_get.
export fn zs_app_setting_get_at(a: ?*const App, z: f64, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.getSettingAt(z, n, &aw.writer) catch |e| return status(e);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

// ---- the plate ----

export fn zs_app_add_stl(a: ?*App, name: ?[*:0]const u8, data: ?[*]const u8, len: usize) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const d = data orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const i = app.addStl(std.mem.span(name orelse "part.stl"), d[0..len]) catch |e| return -@as(isize, status(e));
    noted(app, null, true);
    return @intCast(i);
}

pub const Part = extern struct {
    name: [*:0]const u8,
    x: f64,
    y: f64,
    rotation: f64,
    size_x: f64,
    size_y: f64,
    size_z: f64,
    scale_x: f64,
    scale_y: f64,
    scale_z: f64,
};

export fn zs_app_part_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.plate.count();
}

/// The name stays valid until the plate changes.
export fn zs_app_part_get(a: ?*App, i: usize, out: ?*Part) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    const p = &app.plate.parts.items[i];
    o.* = .{ .name = p.name.ptr, .x = p.x, .y = p.y, .rotation = p.rot, .size_x = 2 * p.half[0], .size_y = 2 * p.half[1], .size_z = p.height, .scale_x = p.scale[0], .scale_y = p.scale[1], .scale_z = p.scale[2] };
    return ok;
}

/// The mesh of part i at its place on the bed (mm): `nv` vertices (x, y,
/// z) and `nf` triangles, in the order of the paint of the part. Valid
/// until the next call or until the app goes.
pub export fn zs_app_part_mesh(a: ?*App, i: usize, verts: ?*[*]const f32, nv: ?*usize, faces: ?*[*]const u32, nf: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    const m = app.plate.partMesh(app.gpa, i) catch return @intFromEnum(Status.out_of_memory);
    if (app.mesh_out) |*old| old.deinit(app.gpa);
    app.mesh_out = m;
    const mo = &app.mesh_out.?;
    if (verts) |o| o.* = @ptrCast(mo.vertices.items.ptr);
    if (nv) |o| o.* = mo.vertices.items.len;
    if (faces) |o| o.* = @ptrCast(mo.faces.items.ptr);
    if (nf) |o| o.* = mo.faces.items.len;
    return ok;
}

/// The paint of part i as text: a line "triangle text" for each painted
/// triangle (the text of the 3MF form, see paint.zig). The same buffer
/// rules as zs_app_setting_get.
export fn zs_app_part_paint_get(a: ?*const App, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    const p = &app.plate.parts.items[i];
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    p.paint.writeLines(p.mesh.faces.items.len, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// Sets the paint of part i from its text (zs_app_part_paint_get). An
/// empty text clears it.
export fn zs_app_part_paint_set(a: ?*App, i: usize, text: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.setPartPaint(i, if (text) |t| t[0..len] else "") catch return @intFromEnum(Status.out_of_memory);
    noted(app, null, true);
    return ok;
}

/// Paints a body of a range of layers with filament `filament` (from 1):
/// the mesh of each part under the beads of `beads` (`n` floats, see
/// zs_view_connected_beads). The filament of a part is no paint on it.
/// `changed` (may be NULL): the count of triangles whose paint changed. A
/// change is a step of the undo list, and the next slice splits the part.
export fn zs_app_paint_body(a: ?*App, beads: ?[*]align(1) const f32, n: usize, filament: u32, changed: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    // A copy with the alignment of f32 (the web app gives bytes).
    const list = gpa.alloc(f32, if (beads != null) n else 0) catch return @intFromEnum(Status.out_of_memory);
    defer gpa.free(list);
    if (beads) |b| for (list, 0..) |*d, i| {
        d.* = b[i];
    };
    const count = app.paintBody(list, filament) catch return @intFromEnum(Status.out_of_memory);
    if (count > 0) noted(app, null, true);
    if (changed) |out| out.* = count;
    return ok;
}

/// A copy of n floats with the alignment of f32 (the web app gives bytes).
fn floatsOf(beads: ?[*]align(1) const f32, n: usize) ?[]f32 {
    const list = gpa.alloc(f32, if (beads != null) n else 0) catch return null;
    if (beads) |b| for (list, 0..) |*d, i| {
        d.* = b[i];
    };
    return list;
}

/// Sets setting `name` of the region of a body of some layers to `value`
/// (NULL: no value of its own). `id` 0: the region of the beads (`n`
/// floats, from zs_view_connected_beads): the region with their box, or
/// a new one. `out_id` (may be NULL): the id of the region, 0 if it went
/// (no setting left). ZS_INVALID_VALUE: a setting that a region cannot
/// have (zs_setting_region_note), or a bad value. A change is a step of
/// the undo list, and the next slice has the region.
export fn zs_app_region_set(a: ?*App, beads: ?[*]align(1) const f32, n: usize, id: u32, name: ?[*:0]const u8, value: ?[*:0]const u8, out_id: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const nm = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const list = floatsOf(beads, n) orelse return @intFromEnum(Status.out_of_memory);
    defer gpa.free(list);
    const r = app.regionSet(list, id, nm, if (value) |v| std.mem.span(v) else null) catch |e| return switch (e) {
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.NoPart, error.NoRegion => @intFromEnum(Status.out_of_range),
        else => @intFromEnum(Status.invalid_value),
    };
    noted(app, null, true);
    if (out_id) |o| o.* = r;
    return ok;
}

/// The id of the region of the beads (their box, see zs_app_region_set),
/// or 0 in `out_id`.
export fn zs_app_region_find(a: ?*App, beads: ?[*]align(1) const f32, n: usize, out_id: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const list = floatsOf(beads, n) orelse return @intFromEnum(Status.out_of_memory);
    defer gpa.free(list);
    const r = app.regionFind(list) catch return @intFromEnum(Status.out_of_memory);
    if (out_id) |o| o.* = r;
    return ok;
}

/// The settings of region `id`, one on each line: "name\tvalue". The
/// same buffer rules as zs_app_setting_get.
export fn zs_app_region_settings(a: ?*const App, id: u32, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.regionSettings(id, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// Why a region of some layers cannot have setting `name` of its own (a
/// short sentence, static), or NULL if it can (see
/// settings.region_settings).
export fn zs_setting_region_note(name: ?[*:0]const u8) ?[*:0]const u8 {
    const n = std.mem.span(name orelse return null);
    const note = zs.settings.regionNote(n) orelse return null;
    return @ptrCast(note.ptr);
}

/// The states that the paint of part i uses: bit k for state k (0 is the
/// filament of the part, k + 1 filament k). 0: no paint.
export fn zs_app_part_paint_used(a: ?*const App, i: usize, out: ?*u32) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    o.* = app.plate.parts.items[i].paint.used();
    return ok;
}

/// The number of filaments of the plate, at least 1 (see
/// app/filament_slots.zig).
export fn zs_app_filament_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app_mod.filament_slots.count(app);
}

/// Adds a filament to the plate: a copy of filament 1 with a new color.
/// `out_index` gets its index (from 0).
export fn zs_app_filament_add(a: ?*App, out_index: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const i = app_mod.filament_slots.add(app) catch |e| return switch (e) {
        error.TooMany => @intFromEnum(Status.out_of_range),
        else => @intFromEnum(Status.out_of_memory),
    };
    if (out_index) |o| o.* = i;
    noted(app, null, true);
    return ok;
}

/// Removes filament i (from 1; filament 0 is the filament of the
/// settings). The parts and the layers of the filaments after it move
/// down by one.
export fn zs_app_filament_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app_mod.filament_slots.remove(app, i) catch |e| return switch (e) {
        error.NoSlot => @intFromEnum(Status.out_of_range),
        else => @intFromEnum(Status.out_of_memory),
    };
    noted(app, null, true);
    return ok;
}

/// Sets a value of filament i: `name` is a filament setting
/// ("filament.color"). Filament 0 is the filament of the settings.
export fn zs_app_filament_set(a: ?*App, i: usize, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    app_mod.filament_slots.set(app, i, n, v) catch |e| return switch (e) {
        error.NoSlot => @intFromEnum(Status.out_of_range),
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_value),
    };
    // A value that the user sets: the slot keeps it when the printer
    // tells other spools (app/printer_filaments.zig).
    app_mod.printer_filaments.markHand(app, i);
    noted(app, if (i == 0) n else null, i != 0);
    return ok;
}

/// A value of filament i, as zs_app_setting_get gives it. The names
/// "source.printer" and "source.hand" give "1" or "0" (the values come
/// from a spool of the printer, or the user set one by hand),
/// "source.tray" the tray of the spool (-1: none), and "source.slot" its
/// holder ("A1", "Ext", or "").
export fn zs_app_filament_get(a: ?*const App, i: usize, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    if (std.mem.startsWith(u8, n, "source.")) {
        if (i >= app_mod.filament_slots.count(app)) return @intFromEnum(Status.out_of_range);
        const m = &app.slot_marks[i];
        const field = n["source.".len..];
        (if (std.mem.eql(u8, field, "printer"))
            aw.writer.writeAll(if (m.printer) "1" else "0")
        else if (std.mem.eql(u8, field, "hand"))
            aw.writer.writeAll(if (m.hand) "1" else "0")
        else if (std.mem.eql(u8, field, "tray"))
            aw.writer.print("{d}", .{m.tray})
        else if (std.mem.eql(u8, field, "slot"))
            aw.writer.writeAll(m.name())
        else
            return @intFromEnum(Status.unknown_setting)) catch return @intFromEnum(Status.out_of_memory);
    } else {
        if (!std.mem.startsWith(u8, n, "filament.")) return @intFromEnum(Status.unknown_setting);
        var s: zs.Settings = .{};
        s.filament = app_mod.filament_slots.get(app, i) orelse return @intFromEnum(Status.out_of_range);
        App.writeSettingOf(s, n, &aw.writer) catch |e| return switch (e) {
            error.WriteFailed => @intFromEnum(Status.out_of_memory),
            else => @intFromEnum(Status.unknown_setting),
        };
    }
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// Applies a filament profile (its text) to filament i (from 1).
/// Filament 0 takes a profile with zs_app_apply_profile.
export fn zs_app_filament_profile(a: ?*App, i: usize, name: ?[*:0]const u8, text: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const t = std.mem.span(text orelse return @intFromEnum(Status.invalid_argument));
    var diag: zs.profile.Diagnostic = .{};
    app_mod.filament_slots.applyProfile(app, i, n, t, &diag) catch |e| return switch (e) {
        error.NoSlot => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_value),
    };
    app_mod.printer_filaments.markHand(app, i);
    noted(app, null, true);
    return ok;
}

/// Makes the filaments of the plate the spools that a printer has loaded
/// (app/printer_filaments.zig): `json` is the reply of a printdeck
/// (GET /api/plugin/printdeck, with "filaments") or the list of
/// zs_printer_status_filaments. flags: 1 the filaments that the user set
/// by hand follow the printer too ("Use the printer's filament"); 2 the
/// automatic follow of a change of the spools, which changes nothing on a
/// printer that pauses for each filament change. `name`
/// is the printer for the message, which goes to `message` (can be NULL).
/// `changed` (can be NULL) gets 1 when a filament changed (slice again).
/// ZS_NO_RESULT when the printer tells no spool that the plate can use.
export fn zs_app_filaments_from_printer(a: ?*App, name: ?[*:0]const u8, json: ?[*]const u8, len: usize, flags: c_int, changed: ?*c_int, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const j = (json orelse return @intFromEnum(Status.invalid_argument))[0..len];
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const pf = app_mod.printer_filaments;
    const spools = pf.parse(ar, j) catch return @intFromEnum(Status.out_of_memory);
    const how: app_mod.printer_filaments.How = if (flags & 1 != 0) .take_hand else if (flags & 2 != 0) .follow else .keep_hand;
    const r = pf.apply(app, spools, how) catch |e| return switch (e) {
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.out_of_range),
    };
    if (message) |m| if (cap > 0) {
        const text = pf.message(ar, app, spools, r, if (name) |p| std.mem.span(p) else "the printer") catch "";
        const k = @min(text.len, cap - 1);
        @memcpy(m[0..k], text[0..k]);
        m[k] = 0;
    };
    if (changed) |ch| ch.* = @intFromBool(r.changed);
    if (r.used == 0) return @intFromEnum(Status.no_result);
    if (r.changed) noted(app, null, true);
    return ok;
}

/// The tray of each filament of the plate (`out`, up to `cap`), for the
/// ams_mapping of a print start on a Bambu Lab printer: the tray of the
/// spool of the printer that the filament comes from (the AMS unit times
/// 4 and the tray; 254 and 255 the external spools), or -1. Returns the
/// count of filaments.
export fn zs_app_ams_mapping(a: ?*const App, out: ?[*]i32, cap: usize) usize {
    const app = a orelse return 0;
    const o = out orelse return app_mod.filament_slots.count(app);
    return app_mod.printer_filaments.amsMapping(app, o[0..cap]);
}

/// The filament of each slot in the last slice: `grams` gets the weight
/// of up to `cap` filaments (with the flush of the changes to each), and
/// `changes` the number of filament changes. `flush_g` gets the weight of
/// all flushes.
export fn zs_app_filament_stats(a: ?*const App, grams: ?[*]f64, cap: usize, changes: ?*u32, flush_g: ?*f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const st = app.result() orelse return @intFromEnum(Status.no_result);
    if (grams) |g| for (0..@min(cap, st.slot_g.len)) |k| {
        g[k] = st.slot_g[k];
    };
    if (changes) |ch| ch.* = st.changes;
    if (flush_g) |f| f.* = if (st.filament_mm > 0) st.flush_mm / st.filament_mm * st.filament_g else 0;
    return ok;
}

/// The waste of the last slice: `chute_g` the flushes that went out of
/// the print (the chute of a Bambu Lab printer), `tower_g` all lines of
/// the prime towers (their walls, grid, brim, and the purge in them),
/// `total_g` all filament of the print with the waste, and `change_s` the
/// time of the filament changes. Each pointer can be NULL.
export fn zs_app_waste(a: ?*const App, chute_g: ?*f64, tower_g: ?*f64, total_g: ?*f64, change_s: ?*f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const st = app.result() orelse return @intFromEnum(Status.no_result);
    const g_per_mm = if (st.filament_mm > 0) st.filament_g / st.filament_mm else 0;
    if (chute_g) |p| p.* = st.chute_mm * g_per_mm;
    if (tower_g) |p| p.* = st.tower_mm * g_per_mm;
    if (total_g) |p| p.* = st.filament_g;
    if (change_s) |p| p.* = st.change_s;
    return ok;
}

/// The settings of part i and of its modifier volumes, as text (see
/// App.partSettingsText). The same buffer rules as zs_app_setting_get.
/// Sets a zslice setting of part i (value NULL: the part has the value of
/// the plate again). See App.setPartSetting.
export fn zs_app_part_setting_set(a: ?*App, i: usize, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v: ?[]const u8 = if (value) |p| std.mem.span(p) else null;
    app.setPartSetting(i, n, v) catch |e| return switch (e) {
        error.NoPart => @intFromEnum(Status.out_of_range),
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_value),
    };
    noted(app, null, true);
    return ok;
}

/// The value of a zslice setting of part i, or ZS_NO_RESULT if the part
/// has the value of the plate. The same buffer rules as
/// zs_app_setting_get.
export fn zs_app_part_setting_get(a: ?*const App, i: usize, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    const text = app.partSetting(i, n) orelse return @intFromEnum(Status.no_result);
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

export fn zs_app_part_settings(a: ?*const App, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.partSettingsText(i, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The settings of part i that zslice does not use (App.partUnusedText).
/// The same buffer rules as zs_app_setting_get.
export fn zs_app_part_unused(a: ?*const App, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.partUnusedText(i, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The zslice settings of Cura settings for the whole plate
/// (import_cura.plateSettings), from the settings of the app now. `text`
/// has one "key=value" a line. Each line of the result is one of:
///   "set\tname\tvalue": a zslice setting to set;
///   "near\tkey\tvalue\twhy": zslice uses a near value;
///   "unused\tkey\tvalue\twhy": zslice cannot use this key.
/// It changes no setting. The same buffer rules as zs_app_setting_get.
export fn zs_app_cura_settings(a: ?*const App, text: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = std.mem.span(text orelse return @intFromEnum(Status.invalid_argument));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pairs: std.ArrayList(zs.import_cura.Pair) = .empty;
    var lines = std.mem.tokenizeAny(u8, t, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return @intFromEnum(Status.invalid_argument);
        pairs.append(arena, .{
            .key = std.mem.trim(u8, line[0..eq], " \t"),
            .value = std.mem.trim(u8, line[eq + 1 ..], " \t"),
        }) catch return @intFromEnum(Status.out_of_memory);
    }
    const ps = zs.import_cura.plateSettings(arena, pairs.items, &app.settings) catch return @intFromEnum(Status.out_of_memory);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    (struct {
        fn f(out: *Writer, r: zs.import_cura.PartSettings) Writer.Error!void {
            for (r.sets) |ch| try out.print("set\t{s}\t{s}\n", .{ ch.name, ch.value });
            for (r.ignored) |ig| try out.print("{s}\t{s}\t{s}\t{s}\n", .{ if (ig.near) "near" else "unused", ig.key, ig.value, ig.why });
        }
    }).f(w, ps) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The parts of a 3MF file keep their places in the file (App.keep_places).
export fn zs_app_set_keep_places(a: ?*App, on: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.keep_places = on != 0;
    return ok;
}

export fn zs_app_part_move(a: ?*App, i: usize, x: f64, y: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.movePart(i, x, y) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_rotate(a: ?*App, i: usize, degrees: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.rotatePart(i, degrees) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_scale(a: ?*App, i: usize, sx: f64, sy: f64, sz: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.scalePart(i, .{ sx, sy, sz }) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// Physics: part i falls over if it cannot stand as it is, and rolls until
/// it rests; with support on, it stays. Call it after a turn ends (the
/// release of a ring, a turn key). Returns the angle of the fall in
/// degrees (0: it stands), or a negative status.
export fn zs_app_part_settle(a: ?*App, i: usize) f64 {
    const app = a orelse return -@as(f64, @floatFromInt(@intFromEnum(Status.invalid_argument)));
    if (i >= app.plate.count()) return -@as(f64, @floatFromInt(@intFromEnum(Status.out_of_range)));
    const deg = app.settlePart(i) catch |e| return -@as(f64, @floatFromInt(status(e)));
    if (deg > 0) noted(app, null, true);
    return deg;
}

/// Starts the fall of part i, for a shell that shows it (see
/// src/rigid.zig): 1 if it falls, 0 if it stands (or support holds it, or
/// a fall runs), or -status.
export fn zs_app_fall_start(a: ?*App, i: usize) c_int {
    const app = a orelse return -@as(c_int, @intFromEnum(Status.invalid_argument));
    const started = app.fallStart(i) catch |e| return -@as(c_int, status(e));
    return @intFromBool(started);
}

/// Runs the fall for dt seconds and writes the frame to out (10 values):
/// the turn qx, qy, qz, qw about the pivot px, py, pz, then the move mx,
/// my, mz, for zs_view_part_preview (flags 0). Returns 1 while it falls,
/// 0 when the part rests (its new place is on the plate: one history
/// step; slice again), -1 with no fall, or -status.
export fn zs_app_fall_step(a: ?*App, dt: f64, out: ?[*]f64) c_int {
    const app = a orelse return -@as(c_int, @intFromEnum(Status.invalid_argument));
    const f = (app.fallStep(dt) catch |e| return -@as(c_int, status(e))) orelse return -1;
    if (out) |o| {
        for (f.q, 0..) |x, k| o[k] = x;
        for (f.pivot, 0..) |x, k| o[4 + k] = x;
        for (f.move, 0..) |x, k| o[7 + k] = x;
    }
    if (f.done) {
        noted(app, null, true);
        return 0;
    }
    return 1;
}

/// The first part that cannot stand as it is while support is off (after
/// support turned off, say), or -1. Start its fall with
/// zs_app_fall_start.
export fn zs_app_fall_pending(a: ?*App) isize {
    const app = a orelse return -1;
    const i = (app.unstablePart() catch return -1) orelse return -1;
    return @intCast(i);
}

/// The hand takes part i at the bed point (x, y, z) mm on its surface: the
/// part follows the hand as a real object (a soft spring pulls that point
/// to the hand). Then zs_app_grab_move for each move of the pointer, and
/// zs_app_fall_step each frame, as for a fall. 1 if it took the part.
export fn zs_app_grab_start(a: ?*App, i: usize, x: f64, y: f64, z: f64) c_int {
    const app = a orelse return -@as(c_int, @intFromEnum(Status.invalid_argument));
    const ok_ = app.grabStart(i, .{ x, y, z }) catch |e| return -@as(c_int, status(e));
    return @intFromBool(ok_);
}

/// The hand moves to the bed point (x, y, z) mm.
export fn zs_app_grab_move(a: ?*App, x: f64, y: f64, z: f64) void {
    const app = a orelse return;
    app.grabMove(.{ x, y, z });
}

/// Turns the part in the hand by `degrees` about the axis (ax, ay, az) of
/// the bed (the hand holds its orientation). Shift in a shell snaps the
/// steps.
export fn zs_app_grab_turn(a: ?*App, ax: f64, ay: f64, az: f64, degrees: f64) void {
    const app = a orelse return;
    app.grabTurn(.{ ax, ay, az }, degrees);
}

/// The hand lets go: the part keeps its speed, falls, and rests; the steps
/// of zs_app_fall_step end it on the plate.
export fn zs_app_grab_end(a: ?*App) void {
    const app = a orelse return;
    app.grabEnd();
}

/// Ends a fall with no change of the plate.
export fn zs_app_fall_cancel(a: ?*App) void {
    const app = a orelse return;
    app.fallCancel();
}

/// 1 if part i can stand as it is on the bed (the bond of its first layer
/// and its brim holds it, see bond.zig), 0 if it falls over, whatever the
/// support setting. With support on, zs_app_part_settle keeps such a part
/// in place: an app can say that the support holds it.
export fn zs_app_part_stands(a: ?*App, i: usize) c_int {
    const app = a orelse return 1;
    if (i >= app.plate.count()) return 1;
    return @intFromBool(app.standsOnBed(i) catch return 1);
}

export fn zs_app_part_turn(a: ?*App, i: usize, axis: c_int, degrees: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count() or axis < 0 or axis > 1) return @intFromEnum(Status.out_of_range);
    app.turnPart(i, @intCast(axis), degrees) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// Part i slices coarse in the next slices (App.setCoarsePart); i < 0:
/// no part. For the live slice of a drag.
export fn zs_app_set_coarse_part(a: ?*App, i: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= 0 and @as(usize, @intCast(i)) >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.setCoarsePart(if (i < 0) null else @intCast(i));
    return ok;
}

/// The next slices are drafts (on != 0) or exact (App.setDraft). For the
/// live slice of a drag or an edit.
export fn zs_app_set_draft(a: ?*App, on: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.setDraft(on != 0);
    return ok;
}

/// 1 if the slice that runs, or the last slice, is a draft.
export fn zs_app_is_draft(a: ?*const App) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.isDraft());
}

export fn zs_app_part_put_down_at(a: ?*App, i: usize, x: f64, y: f64, z: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.putPartDownAt(i, x, y, z) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_place(a: ?*App, i: usize, mode: c_int, axis: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count() or mode < 0 or mode > 2 or axis < 0 or axis > 2) return @intFromEnum(Status.out_of_range);
    app.placePart(i, @enumFromInt(@as(u8, @intCast(mode))), @intCast(axis)) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// A copy of part i at a free place on the bed. Returns its index, or a
/// negative status.
/// Splits part i into its separate bodies, each a part at its place with
/// the settings of part i (the new parts are at index i on). Returns the
/// count of new parts, 0 for a part of one body, or -status.
export fn zs_app_part_split(a: ?*App, i: usize) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return -@as(isize, @intFromEnum(Status.out_of_range));
    const n = app.splitPart(i) catch |e| return -@as(isize, status(e));
    if (n > 0) noted(app, null, true);
    return @intCast(n);
}

/// Cuts part i with a level plane at height z (mm above the bed): the part
/// below and the part above, each closed, with the settings of part i, at
/// index i and i + 1. flip != 0 turns the upper part over, onto its cut
/// face. pegs > 0: at most that many holes for pegs in both parts, and the
/// pegs (diameter `peg_d` mm, 0: 5 mm) as parts at the end of the plate.
/// Returns the count of new parts (2 and the pegs), 0 if the plane misses
/// the part, or -status.
export fn zs_app_part_cut(a: ?*App, i: usize, z: f64, flip: c_int, pegs: c_int, peg_d: f64) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return -@as(isize, @intFromEnum(Status.out_of_range));
    const p: zs.cut.Pegs = .{ .count = @intCast(std.math.clamp(pegs, 0, 8)), .diameter = if (peg_d > 0) peg_d else 5 };
    const n = app.cutPart(i, z, flip != 0, p) catch |e| return -@as(isize, status(e));
    if (n > 0) noted(app, null, true);
    return @intCast(n);
}

export fn zs_app_part_duplicate(a: ?*App, i: usize) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return -@as(isize, @intFromEnum(Status.out_of_range));
    const j = app.duplicatePart(i) catch |e| return -@as(isize, status(e));
    noted(app, null, true);
    return @intCast(j);
}

/// Copies parts `parts` (n indices) of the plate to the clipboard of the
/// process (app/clipboard.zig), with the support areas and marks over
/// them. whole != 0: the whole plate (parts can be NULL).
export fn zs_app_parts_copy(a: ?*const App, parts: ?[*]const usize, n: usize, whole: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const list: []const usize = if (parts) |p| p[0..n] else &.{};
    app_mod.clipboard.copy(app, list, whole != 0) catch |e| return status(e);
    return ok;
}

/// Pastes the clipboard on the plate. at_point != 0: the center of the
/// group at (x, y) mm on the bed. Returns the index of the first new
/// part, or -status (ZS_NO_RESULT: the clipboard is empty).
export fn zs_app_parts_paste(a: ?*App, at_point: c_int, x: f64, y: f64) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (at_point != 0 and !(std.math.isFinite(x) and std.math.isFinite(y))) return -@as(isize, @intFromEnum(Status.invalid_value));
    const at: app_mod.clipboard.At = if (at_point != 0) .{ .point = .{ x, y } } else .free;
    const r = app.pasteParts(null, at) catch |e| return -@as(isize, status(e));
    noted(app, null, true);
    return @intCast(r.first);
}

/// A copy of the whole plate of `from` on the plate of `to` (as a copy
/// and a paste), with no change of the clipboard. Returns the index of
/// the first new part, or -status.
export fn zs_app_plate_copy_to(f: ?*const App, t: ?*App) isize {
    const from = f orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const to = t orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (from == to) return -@as(isize, @intFromEnum(Status.invalid_argument));
    var copy = app_mod.clipboard.make(from, &.{}, true) catch |e| return -@as(isize, status(e));
    defer app_mod.clipboard.free(&copy);
    const r = to.pasteParts(&copy, .free) catch |e| return -@as(isize, status(e));
    noted(to, null, true);
    return @intCast(r.first);
}

/// The count of parts on the clipboard (0: empty).
export fn zs_clipboard_parts() usize {
    return app_mod.clipboard.count();
}

/// 1 if the clipboard has a whole plate.
export fn zs_clipboard_is_plate() c_int {
    return @intFromBool(app_mod.clipboard.isPlate());
}

export fn zs_clipboard_clear() void {
    app_mod.clipboard.clear();
}

/// Mirrors part i along the X (axis 0) or Y (axis 1) axis of the bed.
export fn zs_app_part_mirror(a: ?*App, i: usize, axis: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (axis < 0 or axis > 1) return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.mirrorPart(i, @intCast(axis)) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_reset(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.resetPart(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_plate_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.plateCount();
}

export fn zs_app_plate_active(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.active;
}

export fn zs_app_plate_parts(a: ?*const App, i: usize) usize {
    const app = a orelse return 0;
    return app.plateParts(i);
}

/// A new empty plate (it becomes the active plate). Returns its index.
export fn zs_app_plate_add(a: ?*App) isize {
    const app = a orelse return -1;
    const i = app.addPlate() catch return -1;
    noted(app, null, true);
    return @intCast(i);
}

export fn zs_app_plate_select(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plateCount()) return @intFromEnum(Status.out_of_range);
    app.selectPlate(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_plate_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plateCount()) return @intFromEnum(Status.out_of_range);
    app.removePlate(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// Smart placement of all parts, then an arrange. 1 if they all fit.
export fn zs_app_plate_smart_place(a: ?*App) c_int {
    const app = a orelse return 0;
    defer noted(app, null, true);
    return @intFromBool(app.smartPlacePlate() catch return 0);
}

/// Puts the test of a calibration (calib.Kind) on the empty plate of the
/// app (app/calibrate.zig).
export fn zs_app_calibration_add(a: ?*App, kind: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (kind < 0 or kind > 3) return @intFromEnum(Status.invalid_argument);
    @import("../app/calibrate.zig").add(app, @enumFromInt(@as(u8, @intCast(kind)))) catch |e| return switch (e) {
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        error.NoRetraction => @intFromEnum(Status.invalid_settings),
        error.NotEmpty => @intFromEnum(Status.invalid_argument),
        else => @intFromEnum(Status.invalid_value),
    };
    noted(app, null, true);
    return ok;
}

/// The calibration of the plate as text (calibrate.write), or
/// no_result.
export fn zs_app_calibration_get(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const cal = app.calibration orelse return @intFromEnum(Status.no_result);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    @import("../app/calibrate.zig").write(cal, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// Moves part i to place `to` of the plate list (App.reorderPart).
export fn zs_app_part_reorder(a: ?*App, i: usize, to: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count() or to >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.reorderPart(i, to) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.removePart(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// 1 if each part of the plate is on the bed (with room for the brim at
/// the edges) and overlaps no other part; 0 if a part is off the bed or on
/// another part. After a cut (zs_app_part_cut) or a duplicate, 0 means the
/// parts do not fit on this bed: move some to another plate.
export fn zs_app_plate_fits(a: ?*const App) c_int {
    const app = a orelse return 0;
    // A real fault only: off the bed (with room for the brim), or on
    // another part. Parts nearer than the gap of arrange print well.
    return @intFromBool(app.plate.noFault(app.bedSize(), app.settings.project.brim_width));
}

export fn zs_app_plate_arrange(a: ?*App) c_int {
    const app = a orelse return 0;
    defer noted(app, null, true);
    return @intFromBool(app.arrangePlate() catch false);
}

export fn zs_app_plate_clear(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.clearPlate() catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// The part whose footprint holds (x, y) on the bed, or -1.
export fn zs_app_part_at(a: ?*const App, x: f64, y: f64) isize {
    const app = a orelse return -1;
    const i = app.plate.partAt(x, y) orelse return -1;
    return @intCast(i);
}

/// The part of a path of the toolpaths (by its first point), or -1.
export fn zs_app_part_of_path(a: ?*const App, path: usize) isize {
    const app = a orelse return -1;
    const i = app.partOfPath(path) orelse return -1;
    return @intCast(i);
}

fn groupOf(group: c_int) ?zs.profile.Group {
    return switch (group) {
        0 => .machine,
        1 => .filament,
        2 => .project,
        else => null,
    };
}

/// Writes the settings of a group that differ from the defaults, as a
/// profile. The same buffer rules as zs_app_setting_get.
export fn zs_app_state_write(a: ?*const App, group: c_int, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = groupOf(group) orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeState(g, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const n = @min(text.len, cap - 1);
        @memcpy(b[0..n], text[0..n]);
        b[n] = 0;
    }
    return ok;
}

/// The settings of a group that differ from the built-in defaults: for
/// the project group, the quality profile with the changes of this print
/// (a full profile, for "Save as profile").
export fn zs_app_profile_write(a: ?*const App, group: c_int, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = groupOf(group) orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    zs.profile.writeChanged(app.settings, g, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const n = @min(text.len, cap - 1);
        @memcpy(b[0..n], text[0..n]);
        b[n] = 0;
    }
    return ok;
}

/// Sets all settings of a group to the built-in defaults.
export fn zs_app_group_reset(a: ?*App, group: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.resetGroup(groupOf(group) orelse return @intFromEnum(Status.invalid_argument));
    noted(app, null, false);
    return ok;
}

/// Applies a profile text to a group. On an error, `message` (can be
/// NULL) gets the line and the reason, and the settings do not change.
export fn zs_app_profile_apply(a: ?*App, group: c_int, text: ?[*]const u8, len: usize, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = groupOf(group) orelse return @intFromEnum(Status.invalid_argument);
    const t = (text orelse return @intFromEnum(Status.invalid_argument))[0..len];
    var diag: zs.profile.Diagnostic = .{};
    app.applyProfile(g, "saved", t, &diag) catch |e| {
        if (message) |m| if (cap > 0) {
            const msg = std.fmt.bufPrint(m[0 .. cap - 1], "line {d}: {s}", .{ diag.line, if (diag.message.len > 0) diag.message else @errorName(e) }) catch m[0 .. cap - 1];
            m[msg.len] = 0;
        };
        return switch (e) {
            error.SyntaxError, error.InvalidValue => @intFromEnum(Status.invalid_value),
            error.UnknownSetting => @intFromEnum(Status.unknown_setting),
            error.OutOfRange => @intFromEnum(Status.out_of_range),
            error.OutOfMemory => @intFromEnum(Status.out_of_memory),
            else => @intFromEnum(Status.invalid_argument),
        };
    };
    noted(app, null, false);
    return ok;
}

/// Imports a profile file of PrusaSlicer, OrcaSlicer, Bambu Studio, or
/// Cura (App.importProfile): its values become changes of the settings,
/// as one step of the undo list. The app keeps the report for
/// zs_app_profile_import_report. ZS_INVALID_VALUE: the file is not a
/// profile, and no setting changes.
export fn zs_app_profile_import(a: ?*App, name: ?[*:0]const u8, bytes: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const b = (bytes orelse return @intFromEnum(Status.invalid_argument))[0..len];
    app.import_report.clearRetainingCapacity();
    var aw: Writer.Allocating = .fromArrayList(app.gpa, &app.import_report);
    defer app.import_report = aw.toArrayList();
    app.importProfile(n, b, &aw.writer) catch |e| return switch (e) {
        error.NotProfile => @intFromEnum(Status.invalid_value),
        else => @intFromEnum(Status.out_of_memory),
    };
    noted(app, null, false);
    return ok;
}

/// The report of the last zs_app_profile_import (see
/// import_profile.Result.writeReport).
export fn zs_app_profile_import_report(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    return copyOut(app.import_report.items, buf, cap, out_len);
}

fn profileError(e: anyerror, diag: zs.profile.Diagnostic, message: ?[*]u8, cap: usize) c_int {
    if (message) |m| if (cap > 0) {
        const msg = std.fmt.bufPrint(m[0 .. cap - 1], "line {d}: {s}", .{ diag.line, if (diag.message.len > 0) diag.message else @errorName(e) }) catch m[0 .. cap - 1];
        m[msg.len] = 0;
    };
    return switch (e) {
        error.SyntaxError, error.InvalidValue => @intFromEnum(Status.invalid_value),
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.OutOfRange => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_argument),
    };
}

/// The formula of a setting (the text after "="), or ZS_NO_RESULT. A
/// setting gets a formula from zs_app_setting_set with a value that
/// starts with "=". The same buffer rules as zs_app_setting_get.
export fn zs_app_formula_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const text = app.formulaOf(std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) orelse return @intFromEnum(Status.no_result);
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// All formulas as text ("name = text" lines), for the state of a shell.
export fn zs_app_formulas_write(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeFormulas(&aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// Reads the text of zs_app_formulas_write.
export fn zs_app_formulas_read(a: ?*App, text: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.readFormulas((text orelse return @intFromEnum(Status.invalid_argument))[0..len]);
    noted(app, null, false);
    return ok;
}

/// Sets the quality profile (see App.setQuality).
export fn zs_app_quality_set(a: ?*App, name: ?[*:0]const u8, text: ?[*]const u8, len: usize, keep_edits: bool, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const t = (text orelse return @intFromEnum(Status.invalid_argument))[0..len];
    var diag: zs.profile.Diagnostic = .{};
    app.setQuality(n, t, keep_edits, &diag) catch |e| return profileError(e, diag, message, cap);
    noted(app, null, false);
    return ok;
}

/// The name of the quality profile ("" if none). Valid until the next
/// zs_app_quality_set.
export fn zs_app_quality_name(a: ?*const App) [*:0]const u8 {
    const app = a orelse return "";
    return app.quality_name.ptr;
}

/// Sets the global settings of the user (see App.setGlobal).
export fn zs_app_global_set(a: ?*App, text: ?[*]const u8, len: usize, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = (text orelse return @intFromEnum(Status.invalid_argument))[0..len];
    var diag: zs.profile.Diagnostic = .{};
    app.setGlobal(t, &diag) catch |e| return profileError(e, diag, message, cap);
    noted(app, null, false);
    return ok;
}

/// Sets one global setting (value NULL: clears it). See
/// App.setGlobalSetting.
export fn zs_app_global_setting_set(a: ?*App, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    app.setGlobalSetting(n, if (value) |v| std.mem.span(v) else null) catch |e| return switch (e) {
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_value),
    };
    noted(app, n, false);
    return ok;
}

/// The value of a setting in the global settings (the default if the
/// global settings do not set it).
export fn zs_app_global_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    App.writeSettingOf(app.globalSettings(), n, &aw.writer) catch return @intFromEnum(Status.unknown_setting);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The global settings as a profile text, for the state of a shell.
export fn zs_app_global_write(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeGlobal(&aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// Where the value of a setting comes from (see App.source): the level
/// (enum zs_level) and the name of its profile. `part` < 0: the plate.
export fn zs_app_setting_source(a: ?*const App, part: isize, name: ?[*:0]const u8, level: ?*c_int, profile: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const src = app.source(if (part >= 0) @intCast(part) else null, n);
    if (level) |l| l.* = @intFromEnum(src.level);
    if (profile) |p| if (cap > 0) {
        const k = @min(src.profile.len, cap - 1);
        @memcpy(p[0..k], src.profile[0..k]);
        p[k] = 0;
    };
    return ok;
}

/// The value of a setting under the changes of this print (see App.base):
/// the value that a reset of the setting gives. The same buffer rules as
/// zs_app_setting_get.
export fn zs_app_setting_base_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    App.writeSettingOf(app.base(), n, &aw.writer) catch return @intFromEnum(Status.unknown_setting);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The path of a feature nearest to (x, y) mm on a layer, at any
/// distance, or (size_t)-1.
export fn zs_app_pick_feature(a: ?*const App, layer: usize, feature: c_int, x: f64, y: f64) usize {
    const app = a orelse return std.math.maxInt(usize);
    if (feature < 0 or feature > 255) return std.math.maxInt(usize);
    return app.pickFeature(layer, @intCast(feature), x, y) orelse std.math.maxInt(usize);
}

/// The path of a layer nearest to (x, y) mm, or (size_t)-1.
export fn zs_app_pick_layer(a: ?*const App, layer: usize, x: f64, y: f64) usize {
    const app = a orelse return std.math.maxInt(usize);
    return app.pickInLayer(layer, x, y) orelse std.math.maxInt(usize);
}

pub const License = extern struct {
    name: [*:0]const u8,
    license: [*:0]const u8,
    text: [*:0]const u8,
};

export fn zs_license_count() usize {
    return app_mod.licenses.len;
}

export fn zs_license_get(index: usize, out: ?*License) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (index >= app_mod.licenses.len) return @intFromEnum(Status.out_of_range);
    const l = app_mod.licenses[index];
    o.* = .{ .name = l.name.ptr, .license = l.license.ptr, .text = l.text.ptr };
    return ok;
}

// ---- comparison with Cura ----

/// Reads the file at `path` for the core. Returns its bytes and sets
/// `len`, or returns null. The bytes stay valid until the call that gave
/// the callback returns.
pub const ReadFn = *const fn (ctx: ?*anyopaque, path: [*:0]const u8, len: *usize) callconv(.c) ?[*]const u8;

pub const CuraRow = extern struct {
    name: [*:0]const u8,
    zslice_value: [*:0]const u8,
    cura_value: [*:0]const u8,
    cura_keys: [*:0]const u8,
    from: [*:0]const u8,
    note: [*:0]const u8,
    differs: c_int,
    formula: c_int,
    in_use_all: c_int,
};

/// The rows of a comparison, with the memory of their strings.
pub const CuraCompare = struct {
    arena: std.heap.ArenaAllocator,
    rows: []CuraRow,
};

const CuraReader = struct {
    read: ReadFn,
    ctx: ?*anyopaque,
    fn readFile(ctx: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *const CuraReader = @ptrCast(@alignCast(ctx.?));
        const p = arena.dupeZ(u8, path) catch return null;
        var len: usize = 0;
        const bytes = self.read(self.ctx, p, &len) orelse return null;
        return arena.dupe(u8, bytes[0..len]) catch null;
    }
};

/// Compares the settings of the app with a Cura stack (see
/// src/cura_compare.zig). `read` gives "cura.json" and the files that it
/// names. On an error, `message` (can be NULL) gets the file and the
/// reason.
export fn zs_app_cura_compare(a: ?*const App, read: ?ReadFn, ctx: ?*anyopaque, out: ?*?*CuraCompare, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const r = read orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const cc = gpa.create(CuraCompare) catch return @intFromEnum(Status.out_of_memory);
    cc.arena = .init(gpa);
    const arena = cc.arena.allocator();
    var reader: CuraReader = .{ .read = r, .ctx = ctx };
    var diag: zs.cura_compare.Diagnostic = .{};
    const rows = zs.cura_compare.compare(arena, app.settings, .{ .ctx = &reader, .read = CuraReader.readFile }, &diag) catch |e| {
        if (message) |m| if (cap > 0) {
            const msg = std.fmt.bufPrint(m[0 .. cap - 1], "{s}: {s}", .{ diag.file, if (diag.message.len > 0) diag.message else @errorName(e) }) catch m[0 .. cap - 1];
            m[msg.len] = 0;
        };
        cc.arena.deinit();
        gpa.destroy(cc);
        return switch (e) {
            error.OutOfMemory => @intFromEnum(Status.out_of_memory),
            else => @intFromEnum(Status.invalid_value),
        };
    };
    cc.rows = cRows(arena, rows) catch {
        cc.arena.deinit();
        gpa.destroy(cc);
        return @intFromEnum(Status.out_of_memory);
    };
    o.* = cc;
    return ok;
}

fn cRows(arena: std.mem.Allocator, rows: []const zs.cura_compare.Row) ![]CuraRow {
    const out = try arena.alloc(CuraRow, rows.len);
    for (rows, out) |src, *dst| dst.* = .{
        .name = (try arena.dupeZ(u8, src.name)).ptr,
        .zslice_value = (try arena.dupeZ(u8, src.zslice)).ptr,
        .cura_value = (try arena.dupeZ(u8, src.cura)).ptr,
        .cura_keys = (try arena.dupeZ(u8, src.cura_keys)).ptr,
        .from = (try arena.dupeZ(u8, src.from)).ptr,
        .note = (try arena.dupeZ(u8, src.note)).ptr,
        .differs = @intFromBool(src.differs),
        .formula = @intFromBool(src.formula),
        .in_use_all = @intFromBool(src.in_use_all),
    };
    return out;
}

export fn zs_cura_compare_count(cc: ?*const CuraCompare) usize {
    const c_ = cc orelse return 0;
    return c_.rows.len;
}

export fn zs_cura_compare_get(cc: ?*const CuraCompare, i: usize, out: ?*CuraRow) c_int {
    const c_ = cc orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= c_.rows.len) return @intFromEnum(Status.out_of_range);
    o.* = c_.rows[i];
    return ok;
}

export fn zs_cura_compare_free(cc: ?*CuraCompare) void {
    const c_ = cc orelse return;
    c_.arena.deinit();
    gpa.destroy(c_);
}

test "C API: the app" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    try std.testing.expectEqual(@intFromEnum(Status.no_model), zs_app_slice(app));
    var info: SettingInfo = undefined;
    try std.testing.expectEqual(ok, zs_setting_get_info(0, &info));
    try std.testing.expectEqualStrings("machine.name", std.mem.span(info.name));
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    try std.testing.expectEqual(ok, zs_app_setting_get(app, "machine.name", &buf, buf.len, &len));
    try std.testing.expectEqual(@as(usize, 7), len);
    try std.testing.expectEqualStrings("generic", std.mem.span(@as([*:0]u8, @ptrCast(&buf))));
    var lic: License = undefined;
    try std.testing.expectEqual(ok, zs_license_get(0, &lic));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(lic.text), "AFFERO") != null);
}

test "C API: import a profile of another slicer" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    const ini = "layer_height = 0.12\nperimeter_speed = 75\nfoo_bar = 3\n";
    try std.testing.expectEqual(ok, zs_app_profile_import(app, "a.ini", ini.ptr, ini.len));
    try std.testing.expectEqual(@as(f64, 0.12), app.?.settings.project.layer_height);
    try std.testing.expectEqual(@as(f64, 0.5), app.?.settings.project.inner_wall_speed);
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    try std.testing.expectEqual(ok, zs_app_profile_import_report(app, &buf, buf.len, &len));
    const rep = buf[0..len];
    try std.testing.expect(std.mem.startsWith(u8, rep, "format\tPrusaSlicer config\n"));
    try std.testing.expect(std.mem.indexOf(u8, rep, "set\tperimeter_speed\t75\tproject.inner_wall_speed\t0.5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "unused\tfoo_bar\t3\t") != null);
    // A file that is not a profile changes nothing.
    try std.testing.expectEqual(@intFromEnum(Status.invalid_value), zs_app_profile_import(app, "b.stl", "solid x\n", 8));
    try std.testing.expectEqual(@as(f64, 0.12), app.?.settings.project.layer_height);
}

test "C API: the simulated print of a slab over air: the first failed layer and each layer" {
    const t = std.testing;
    const alloc = t.allocator;
    var a: ?*App = null;
    try t.expectEqual(ok, zs_app_new(null, null, &a));
    defer zs_app_free(a);
    // A post with a slab 25 mm out over air on each side.
    var b: zs.mesh.Builder = .init(alloc);
    errdefer b.deinit();
    try zs.mesh.shapes.addBox(&b, 25, 0, 0, 31, 6, 4);
    try zs.mesh.shapes.addBox(&b, 0, 0, 4, 56, 6, 5);
    var mesh = try b.finish();
    defer mesh.deinit(alloc);
    var stl: Writer.Allocating = .init(alloc);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    try t.expectEqual(ok, zs_app_load_stl(a, "slab.stl", stl.written().ptr, stl.written().len));
    try t.expectEqual(ok, zs_app_slice(a));
    a.?.stopWorkerForTest();
    var st: PrintSimStats = undefined;
    try t.expectEqual(@intFromEnum(Status.no_result), zs_app_sim_stats(a, &st));
    try t.expectEqual(ok, zs_app_simulate_print(a, &st));
    try t.expect(st.failed > 0);
    try t.expect(st.first_failed_layer > 0);
    try t.expect(st.max_drop > 1.5);
    try t.expectEqualStrings("PLA", std.mem.sliceTo(&st.material, 0));
    try t.expectEqual(@as(c_int, 1), st.material_exact);
    var again: PrintSimStats = undefined;
    try t.expectEqual(ok, zs_app_sim_stats(a, &again));
    try t.expectEqual(st.first_failed_layer, again.first_failed_layer);
    // The first failed layer has failed masses, and the post under it none.
    var drop: f32 = 0;
    var failed: u32 = 0;
    try t.expectEqual(ok, zs_app_sim_layer(a, @intCast(st.first_failed_layer), &drop, &failed));
    try t.expect(failed > 0 and drop > 1.5);
    try t.expectEqual(ok, zs_app_sim_layer(a, 2, &drop, &failed));
    try t.expectEqual(@as(u32, 0), failed);
    try t.expectEqual(@intFromEnum(Status.invalid_argument), zs_app_sim_layer(a, 100000, &drop, &failed));
}

test "C API: the thread count is no pending edit of the undo list" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    try std.testing.expectEqual(ok, zs_app_setting_set(app, "engine.threads", "3"));
    try std.testing.expectEqual(@as(u32, 3), app.?.settings.engine.threads);
    try std.testing.expectEqual(@as(c_int, 0), zs_app_history_pending(app));
    try std.testing.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "4"));
    try std.testing.expectEqual(@as(c_int, 1), zs_app_history_pending(app));
}

test "C API: apply the status of a printer" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    const st = zs_printer_status_new();
    defer zs_printer_status_free(st);
    const body = "{\"material\":\"PETG\",\"diameter\":2.85,\"spool\":{\"name\":\"Navy\",\"color\":\"#1a2b4c\"},\"limits\":{\"max_accel\":1500}}";
    try std.testing.expectEqual(ok, zs_printer_status_feed(st, 2, "/api/plugin/printdeck", body, body.len));
    try std.testing.expectEqual(ok, zs_app_apply_printer_status(app, st, 3));
    const a = app.?;
    try std.testing.expectEqual(@as(f64, 1500), a.settings.machine.max_accel);
    try std.testing.expectEqualStrings("Navy", a.settings.filament.name);
    try std.testing.expectEqualStrings("PETG", a.settings.filament.material);
    try std.testing.expectEqualStrings("#1a2b4c", a.settings.filament.color);
    try std.testing.expectEqual(@as(f64, 2.85), a.settings.filament.diameter);
}

test "C API: compare with Cura" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    const Files = struct {
        fn read(ctx: ?*anyopaque, path: [*:0]const u8, len: *usize) callconv(.c) ?[*]const u8 {
            _ = ctx;
            const p = std.mem.span(path);
            const text: []const u8 = if (std.mem.eql(u8, p, "cura.json"))
                \\{"machine": "box", "profiles": {"q": {"quality_changes": "q.inst.cfg"}}}
            else if (std.mem.eql(u8, p, "definitions/box.def.json"))
                \\{"name": "Box", "inherits": "fdmprinter", "overrides": {"machine_width": {"default_value": 123}}}
            else if (std.mem.eql(u8, p, "q.inst.cfg"))
                "[values]\nlayer_height = 0.25\n"
            else
                return null;
            len.* = text.len;
            return text.ptr;
        }
    };
    var cc: ?*CuraCompare = null;
    var msg: [128]u8 = undefined;
    try std.testing.expectEqual(ok, zs_app_cura_compare(app, Files.read, null, &cc, &msg, msg.len));
    defer zs_cura_compare_free(cc);
    var found: usize = 0;
    for (0..zs_cura_compare_count(cc)) |i| {
        var row: CuraRow = undefined;
        try std.testing.expectEqual(ok, zs_cura_compare_get(cc, i, &row));
        if (std.mem.eql(u8, std.mem.span(row.name), "machine.bed_size_x")) {
            try std.testing.expectEqualStrings("123", std.mem.span(row.cura_value));
            try std.testing.expectEqual(@as(c_int, 1), row.in_use_all);
            found += 1;
        }
        if (std.mem.eql(u8, std.mem.span(row.name), "project.layer_height")) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    // A missing file gives its name.
    const None = struct {
        fn read(ctx: ?*anyopaque, path: [*:0]const u8, len: *usize) callconv(.c) ?[*]const u8 {
            _ = ctx;
            _ = path;
            _ = len;
            return null;
        }
    };
    var cc2: ?*CuraCompare = null;
    try std.testing.expect(zs_app_cura_compare(app, None.read, null, &cc2, &msg, msg.len) != ok);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(@as([*:0]u8, @ptrCast(&msg))), "cura.json:"));
}

// ---- the history of changes (see app/history.zig) ----

fn copyOut(text: []const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const n = @min(text.len, cap - 1);
        @memcpy(b[0..n], text[0..n]);
        b[n] = 0;
    }
    return ok;
}

/// The facts of the state, for a step of the history: one line for each
/// value that differs from the start ("scope\tkey\tvalue").
// ---- refinements: the first slice is a guide ----

/// The records of the refinements of the plate: its changes from the first
/// slice, one on each line (see src/app/refine.zig).
export fn zs_app_refine_records(a: ?*App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeRefinements(gpa, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The store with the records of `project` replaced by `records`.
export fn zs_refine_merge(store: ?[*]const u8, store_len: usize, project: ?[*:0]const u8, records: ?[*]const u8, records_len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const p = std.mem.span(project orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.refine.merge(gpa, if (store) |s| s[0..store_len] else "", p, if (records) |r| r[0..records_len] else "", &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The suggestions for the plate of the app from the store: refinements of
/// at least two other projects with the same material and nozzle.
export fn zs_app_refine_suggest(a: ?*App, store: ?[*]const u8, store_len: usize, project: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const p = std.mem.span(project orelse return @intFromEnum(Status.invalid_argument));
    var now: Writer.Allocating = .init(gpa);
    defer now.deinit();
    app.writeFacts(&now.writer) catch return @intFromEnum(Status.out_of_memory);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.refine.suggest(gpa, if (store) |s| s[0..store_len] else "", p, now.written(), app.refineContext(), &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// Applies one suggestion line of zs_app_refine_suggest. Slice again after
/// it. One history step.
export fn zs_app_refine_apply(a: ?*App, line: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const l = (line orelse return @intFromEnum(Status.invalid_argument))[0..len];
    app.applySuggestion(l) catch |e| return switch (e) {
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        error.NoPart => @intFromEnum(Status.no_model),
        else => @intFromEnum(Status.invalid_argument),
    };
    app.undo.note(gpa, "*", true);
    return ok;
}

export fn zs_app_history_facts(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeFacts(&aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The changes from the facts `before` to the facts `after`, one on each
/// line ("scope\tkey\told\tnew").
export fn zs_history_diff(before: ?[*]const u8, before_len: usize, after: ?[*]const u8, after_len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const b = if (before) |p| p[0..before_len] else "";
    const af = if (after) |p| p[0..after_len] else "";
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.history.diff(gpa, b, af, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The changes of a diff in words, one on each line: "scope\tchange", for
/// example "Part Benchy\tWall count the print value → 4".
export fn zs_history_describe(changes: ?[*]const u8, len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const t = if (changes) |p| p[0..len] else "";
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.history.describe(gpa, t, zs.settings.part_z, &.{}, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// zs_history_describe, with the layer numbers of the last slice of the app
/// for the changes of some layers ("Layers 86 and up").
export fn zs_app_history_describe(a: ?*const App, changes: ?[*]const u8, len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = if (changes) |p| p[0..len] else "";
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.describeChanges(t, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// Undoes one change (one line of zs_history_diff) and keeps the others.
/// ZS_NOT_SUPPORTED for a change of the place of a part. Slice again after
/// it.
export fn zs_app_history_revert(a: ?*App, change: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const line = (change orelse return @intFromEnum(Status.invalid_argument))[0..len];
    app.revertChange(line) catch |e| return switch (e) {
        error.NotSupported => @intFromEnum(Status.not_supported),
        error.NoPart, error.NotPerLayer => @intFromEnum(Status.invalid_argument),
        else => status(e),
    };
    // A new step: it never amends the step of an edit.
    const settings = std.mem.startsWith(u8, line, "machine\t") or std.mem.startsWith(u8, line, "filament\t") or std.mem.startsWith(u8, line, "print\t");
    noted(app, null, !settings);
    return ok;
}

// ---- the undo list (see app/history.zig) ----

fn keyOf(key: ?[*:0]const u8) ?[]const u8 {
    return if (key) |k| std.mem.span(k) else null;
}

/// Ends the step of the changes so far. 1 if a step was added, amended,
/// or dropped.
export fn zs_app_history_commit(a: ?*App, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.undo.commit(app, now_ms));
}

/// The setting whose editor has the focus (NULL: none). 1 if the commit
/// of the edit before changed the list.
export fn zs_app_history_set_focus(a: ?*App, key: ?[*:0]const u8, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.undo.setFocus(app, keyOf(key), now_ms));
}

export fn zs_app_history_undo(a: ?*App, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.undo(app, now_ms));
}

export fn zs_app_history_redo(a: ?*App, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.redo(app, now_ms));
}

export fn zs_app_history_goto(a: ?*App, i: usize, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.goto(app, i, now_ms));
}

export fn zs_app_history_truncate(a: ?*App, i: usize, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.truncate(app, i, now_ms));
}

/// Drops all steps. The next commit takes the start.
export fn zs_app_history_reset(a: ?*App) void {
    const app = a orelse return;
    app.undo.reset(app.gpa);
}

export fn zs_app_history_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.undo.count();
}

export fn zs_app_history_current(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.undo.current;
}

/// 1 if changes wait for a commit.
export fn zs_app_history_pending(a: ?*const App) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.undo.pending_key != null);
}

pub const HistoryStep = extern struct {
    time_ms: i64,
    kind: [*:0]const u8,
    changes: [*]const u8,
    changes_len: usize,
    text: [*]const u8,
    text_len: usize,
};

/// Step i of the undo list: its time, its kind, and its changes from step
/// i - 1 (as lines and in words). The strings are valid until the next
/// zs_app_history_step or the next change of the list.
export fn zs_app_history_step(a: ?*App, i: usize, out: ?*HistoryStep) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const info = app.undo.step(app, i) catch |e| return switch (e) {
        error.OutOfRange => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
    };
    o.* = .{
        .time_ms = info.time_ms,
        .kind = info.kind.ptr,
        .changes = info.changes.ptr,
        .changes_len = info.changes.len,
        .text = info.text.ptr,
        .text_len = info.text.len,
    };
    return ok;
}

/// The kind of a step of the history, from its changes (zs_history_diff
/// lines): "walls", "infill", "surface", "speed", "heat", "support",
/// "layers", "move", "rotate", "scale", "add", "remove", "quality",
/// "printer", "filament", "label", or "other". A static string.
export fn zs_history_kind(changes: ?[*]const u8, len: usize) [*:0]const u8 {
    const t = if (changes) |p| p[0..len] else "";
    const k = app_mod.history.stepKind(gpa, t) catch return "other";
    return @tagName(k);
}

/// The measurements of a path at one of its segments.
pub const CMeasure = extern struct {
    segment_length: f64,
    edge_length: f64,
    path_length: f64,
    closed: c_int,
    size_x: f64,
    size_y: f64,
    shape: c_int,
    radius: f64,
    center_x: f64,
    center_y: f64,
    angle: f64,
};

export fn zs_app_measure(a: ?*const App, path: usize, seg: usize, out: ?*CMeasure) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const m = app.measurePath(path, seg) catch |e| return switch (e) {
        error.NoResult => @intFromEnum(Status.no_result),
        error.OutOfRange => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
    };
    o.* = .{
        .segment_length = m.segment_length,
        .edge_length = m.edge_length,
        .path_length = m.path_length,
        .closed = @intFromBool(m.closed),
        .size_x = m.size[0],
        .size_y = m.size[1],
        .shape = @intFromEnum(m.shape),
        .radius = m.radius,
        .center_x = m.center[0],
        .center_y = m.center[1],
        .angle = m.angle,
    };
    return ok;
}

/// An app with one box on the plate, and the start of its undo list.
fn historyTestApp() !*App {
    var a: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &a));
    errdefer zs_app_free(a);
    var mesh = try zs.mesh.shapes.box(gpa, 20, 20, 10);
    defer mesh.deinit(gpa);
    var stl: Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    try std.testing.expectEqual(ok, zs_app_load_stl(a, "box.stl", stl.written().ptr, stl.written().len));
    try std.testing.expectEqual(@as(c_int, 0), zs_app_history_commit(a, 0));
    try std.testing.expectEqual(@as(usize, 1), zs_app_history_count(a));
    return a.?;
}

fn settingOf(app: *App, name: [*:0]const u8) []const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    var len: usize = 0;
    _ = zs_app_setting_get(app, name, &S.buf, S.buf.len, &len);
    return S.buf[0..len];
}

test "C API: the undo list: one step for an edit with the focus, undo, redo, goto, and truncate" {
    const t = std.testing;
    const app = try historyTestApp();
    defer zs_app_free(app);
    var step: HistoryStep = undefined;

    // Three changes of the infill while its editor has the focus: one step.
    _ = zs_app_history_set_focus(app, "project.infill_density", 1);
    for ([_][*:0]const u8{ "0.3", "0.4", "0.5" }, 0..) |v, k| {
        try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", v));
        try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, @intCast(10 + k)));
    }
    try t.expectEqual(@as(usize, 2), zs_app_history_count(app));
    try t.expectEqual(ok, zs_app_history_step(app, 1, &step));
    try t.expectEqualStrings("infill", std.mem.span(step.kind));
    try t.expectEqualStrings("This print\tInfill density 20 % → 50 %\n", step.text[0..step.text_len]);
    try t.expectEqual(@as(i64, 12), step.time_ms);
    // A commit with no change keeps the edit open.
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 20));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.6"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 21));
    try t.expectEqual(@as(usize, 2), zs_app_history_count(app));

    // The walls: a new step.
    _ = zs_app_history_set_focus(app, "project.wall_count", 30);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "4"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 31));
    try t.expectEqual(@as(usize, 3), zs_app_history_count(app));

    // A move of the part: a step.
    _ = zs_app_history_set_focus(app, null, 40);
    var part: Part = undefined;
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    const x0 = part.x;
    try t.expectEqual(ok, zs_app_part_move(app, 0, x0 + 30, part.y));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 41));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));
    try t.expectEqual(ok, zs_app_history_step(app, 3, &step));
    try t.expectEqualStrings("move", std.mem.span(step.kind));
    try t.expectEqual(ok, zs_app_history_step(app, 0, &step));
    try t.expectEqualStrings("start", std.mem.span(step.kind));

    // Undo three times: the move, the walls, the infill.
    const H = app_mod.history;
    const undo1 = zs_app_history_undo(app, 50);
    try t.expect(undo1 & H.restored_moved != 0 and undo1 & H.restored_plate != 0);
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    try t.expectApproxEqAbs(x0, part.x, 1e-6);
    const undo2 = zs_app_history_undo(app, 51);
    try t.expect(undo2 & H.restored_plate == 0 and undo2 & (H.restored_group << 2) != 0);
    try t.expectEqualStrings("2", settingOf(app, "project.wall_count"));
    try t.expect(zs_app_history_undo(app, 52) != 0);
    try t.expectEqualStrings("0.2", settingOf(app, "project.infill_density"));
    try t.expectEqual(@as(usize, 0), zs_app_history_current(app));
    try t.expectEqual(@as(c_int, 0), zs_app_history_undo(app, 53));
    // A restore is not a change: no step waits, and a commit adds none.
    try t.expectEqual(@as(c_int, 0), zs_app_history_pending(app));
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 54));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));

    // Redo, then go to the last step.
    try t.expect(zs_app_history_redo(app, 60) != 0);
    try t.expectEqualStrings("0.6", settingOf(app, "project.infill_density"));
    try t.expect(zs_app_history_goto(app, 3, 61) & H.restored_plate != 0);
    try t.expectEqual(@as(usize, 3), zs_app_history_current(app));
    try t.expectEqualStrings("4", settingOf(app, "project.wall_count"));
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    try t.expectApproxEqAbs(x0 + 30, part.x, 1e-6);
    try t.expectEqual(@as(c_int, 0), zs_app_history_goto(app, 3, 62));

    // Clear the history after step 1: it goes to step 1 first.
    const tr = zs_app_history_truncate(app, 1, 70);
    try t.expect(tr & H.restored_dropped != 0 and tr & H.restored_moved != 0);
    try t.expectEqual(@as(usize, 2), zs_app_history_count(app));
    try t.expectEqual(@as(usize, 1), zs_app_history_current(app));
    try t.expectEqualStrings("2", settingOf(app, "project.wall_count"));
    try t.expectEqual(@as(c_int, 0), zs_app_history_redo(app, 71));

    // A revert of one change is a new step.
    try t.expectEqual(ok, zs_app_history_step(app, 1, &step));
    const line = try gpa.dupe(u8, step.changes[0..step.changes_len]);
    defer gpa.free(line);
    try t.expectEqual(ok, zs_app_history_revert(app, line.ptr, line.len));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 80));
    try t.expectEqual(@as(usize, 3), zs_app_history_count(app));
    try t.expectEqualStrings("0.2", settingOf(app, "project.infill_density"));

    // A reset drops the steps; the next commit takes the start.
    zs_app_history_reset(app);
    try t.expectEqual(@as(usize, 0), zs_app_history_count(app));
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 90));
    try t.expectEqual(@as(usize, 1), zs_app_history_count(app));
}

test "C API: the undo list: an edit back at its old value drops its step; other keys make new steps" {
    const t = std.testing;
    const app = try historyTestApp();
    defer zs_app_free(app);
    _ = zs_app_history_set_focus(app, "project.infill_density", 1);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.4"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 2));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.2"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 3));
    try t.expectEqual(@as(usize, 1), zs_app_history_count(app));
    // With no focus, each commit is a step.
    _ = zs_app_history_set_focus(app, null, 4);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.4"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 5));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.5"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 6));
    try t.expectEqual(@as(usize, 3), zs_app_history_count(app));
    // A move of the focus commits the edit before it.
    _ = zs_app_history_set_focus(app, "project.infill_density", 7);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.6"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_set_focus(app, "project.wall_count", 8));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));
    // Two settings at once: a step that the next edit does not amend.
    _ = zs_app_history_set_focus(app, "project.wall_count", 9);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "3"));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.7"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 10));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "5"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 11));
    try t.expectEqual(@as(usize, 6), zs_app_history_count(app));
}

test "C API: the undo list keeps at most max_steps steps and max_plate_bytes of plates" {
    const t = std.testing;
    const app = try historyTestApp();
    defer zs_app_free(app);
    app.undo.max_steps = 3;
    for (0..6) |k| {
        var buf: [16]u8 = undefined;
        const v = try std.fmt.bufPrintZ(&buf, "0.{d}", .{k + 3});
        try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", v.ptr));
        try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, @intCast(k)));
    }
    try t.expectEqual(@as(usize, 3), zs_app_history_current(app));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));
    // Steps with the same plate share its snapshot: the cap counts it once.
    const file = try app.writeSnapshotAlloc(gpa);
    const size = file.len;
    gpa.free(file);
    app.undo.max_steps = 100;
    app.undo.max_plate_bytes = size + size / 2;
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.9"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 10));
    try t.expectEqual(@as(usize, 4), zs_app_history_current(app));
    var part: Part = undefined;
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    for (0..3) |k| {
        try t.expectEqual(ok, zs_app_part_move(app, 0, part.x + @as(f64, @floatFromInt(k + 1)), part.y));
        try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, @intCast(20 + k)));
    }
    // Before the step now: one plate file is left.
    try t.expectEqual(@as(usize, 1), zs_app_history_current(app));
}

test "C API: the support trees: list, edit, undo, and reset" {
    const t = std.testing;
    var a: ?*App = null;
    try t.expectEqual(ok, zs_app_new(null, null, &a));
    defer zs_app_free(a);
    // A mushroom: a post and a cap from z 5 to 7.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try zs.mesh.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var stl: Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    try t.expectEqual(ok, zs_app_setting_set(a, "project.support", "everywhere"));
    try t.expectEqual(ok, zs_app_setting_set(a, "project.support_style", "tree"));
    try t.expectEqual(ok, zs_app_load_stl(a, "mushroom.stl", stl.written().ptr, stl.written().len));
    // No slice yet: busy.
    try t.expectEqual(-@as(isize, @intFromEnum(Status.busy)), zs_app_support_tree_nodes(a, 0, null, 0));
    try t.expectEqual(ok, zs_app_slice(a));
    a.?.stopWorkerForTest();
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(a, 0));
    const n: usize = @intCast(zs_app_support_tree_nodes(a, 0, null, 0));
    try t.expect(n > 0);
    const nodes = try gpa.alloc(TreeNode, n);
    defer gpa.free(nodes);
    try t.expectEqual(@as(isize, @intCast(n)), zs_app_support_tree_nodes(a, 0, nodes.ptr, n));
    try t.expectEqual(@as(c_int, 0), zs_app_support_tree_edited(a, 0));
    // A node under the cap, and its tree on the bed.
    var tip: u32 = 0;
    while (nodes[tip].flags & 1 == 0) tip += 1;
    try t.expect(nodes[tip].z > 3 and nodes[tip].z < 5);
    try t.expect(nodes[tip].r >= nodes[tip].r_min);
    // A radius under the rules: clamped.
    var clamp: u32 = 0;
    const root: u32 = @intCast(for (nodes, 0..) |nd, k| {
        if (nd.flags & 2 != 0) break k;
    } else unreachable);
    try t.expectEqual(ok, zs_app_support_tree_set_radius(a, 0, root, 0.01, &clamp));
    try t.expectEqual(@as(u32, 4), clamp);
    try t.expectEqual(@as(c_int, 1), zs_app_support_tree_edited(a, 0));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(a, 1000));
    // A node out of range.
    try t.expectEqual(@as(c_int, @intFromEnum(Status.out_of_range)), zs_app_support_tree_move_node(a, 0, 1_000_000, 0, 0, null));
    // Delete a tree, and add a branch.
    try t.expect(zs_app_support_tree_delete_branch(a, 0, root) > 0);
    const box = a.?.plate.parts.items[0].footprint();
    const cx = (box[0] + box[2]) / 2;
    const cy = (box[1] + box[3]) / 2;
    const got = zs_app_support_tree_add_branch(a, 0, cx + 7, cy, cx + 7, cy, 5, &clamp);
    try t.expect(got >= 0);
    try t.expectEqual(@as(u32, 0), clamp);
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(a, 2000));
    // Undo the add and the delete, then the radius: the plan again.
    try t.expect(zs_app_history_undo(a, 3000) != 0);
    try t.expect(zs_app_history_undo(a, 4000) != 0);
    try t.expectEqual(@as(c_int, 0), zs_app_support_tree_edited(a, 0));
    try t.expect(zs_app_history_redo(a, 5000) != 0);
    try t.expectEqual(@as(c_int, 1), zs_app_support_tree_edited(a, 0));
    try t.expectEqual(@as(c_int, 1), zs_app_support_tree_reset(a, 0));
    try t.expectEqual(@as(c_int, 0), zs_app_support_tree_reset(a, 0));
    var note: [128]u8 = undefined;
    try t.expectEqual(@as(usize, 0), zs_app_support_tree_note(a, &note, note.len));
}

test "C API: a commit with no change keeps the time of the step, also after an undo" {
    const t = std.testing;
    const app = try historyTestApp();
    defer zs_app_free(app);
    var step: HistoryStep = undefined;
    _ = zs_app_history_set_focus(app, "project.infill_density", 1);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.3"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 10));
    _ = zs_app_history_set_focus(app, "project.wall_count", 20);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "4"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 21));
    // No change at 500: both steps keep their times.
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 500));
    try t.expectEqual(ok, zs_app_history_step(app, 2, &step));
    try t.expectEqual(@as(i64, 21), step.time_ms);
    // An undo at 600, then no change at 700: step 1 keeps its time.
    _ = zs_app_history_undo(app, 600);
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 700));
    try t.expectEqual(ok, zs_app_history_step(app, 1, &step));
    try t.expectEqual(@as(i64, 10), step.time_ms);
    try t.expectEqual(ok, zs_app_history_step(app, 2, &step));
    try t.expectEqual(@as(i64, 21), step.time_ms);
}

/// The G-code of the filaments of an X2D plate: each "M620 S<n>A" (the
/// AMS loads filament n + 1) and each "T<n>" of a filament (not T65279
/// and T65535 of the end) loads slot `want`. Returns the count of loads.
fn expectLoads(g: []const u8, want: u32) !usize {
    var it = std.mem.splitScalar(u8, g, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        const tl = std.mem.trim(u8, line, " \t");
        const num: []const u8 = if (std.mem.startsWith(u8, tl, "M620 S")) tl[6..] else if (tl.len > 1 and tl[0] == 'T') tl[1..] else continue;
        const end = std.mem.indexOfNone(u8, num, "0123456789") orelse num.len;
        if (end == 0) continue;
        if (tl[0] == 'M' and (end >= num.len or num[end] != 'A')) continue;
        const k = try std.fmt.parseInt(u32, num[0..end], 10);
        if (k >= 1000) continue;
        if (k != want) {
            std.debug.print("loads filament {d}, not {d}: {s}\n", .{ k + 1, want + 1, tl });
            return error.TestUnexpectedResult;
        }
        n += 1;
    }
    return n;
}

test "C API: the spools of an X2D: the filament of a part is the same in the view, the G-code, the trays, and the file" {
    const t = std.testing;
    const al = t.allocator;
    const printers = zs.printers;
    if (printers.builtin_data.len == 0) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(al);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const lib = try printers.Library.parse(al, printers.builtin_data);
    defer lib.deinit();
    var text: Writer.Allocating = .init(ar);
    try lib.profileText(lib.find("bambu-lab-x2d").?, 0, &text.writer);
    var a: ?*App = null;
    try t.expectEqual(ok, zs_app_new(null, null, &a));
    defer zs_app_free(a);
    try t.expectEqual(ok, zs_app_profile_apply(a, 0, text.written().ptr, text.written().len, null, 0));
    // A post with a slab over air on it: tree support under the slab.
    var b: zs.mesh.Builder = .init(al);
    try zs.mesh.shapes.addBox(&b, 25, 0, 0, 31, 6, 8);
    try zs.mesh.shapes.addBox(&b, 10, 0, 8, 46, 6, 10);
    var mesh = try b.finish();
    var stl: Writer.Allocating = .init(al);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    mesh.deinit(al);
    try t.expectEqual(ok, zs_app_load_stl(a, "t.stl", stl.written().ptr, stl.written().len));
    try t.expectEqual(ok, zs_app_setting_set(a, "project.support", "everywhere"));
    try t.expectEqual(ok, zs_app_setting_set(a, "project.support_style", "tree"));
    // The spools of a printdeck (GET /api/plugin/printdeck): four AMS
    // trays on the main nozzle, and the external spool on the second.
    const json =
        \\{"filaments":[{"slot":"A1","tray":0,"material":"PLA","color":"#898989","idx":"GFL99"},
        \\{"slot":"A2","tray":1,"material":"PLA","color":"#dcdcdc","idx":"GFL99"},
        \\{"slot":"A3","tray":2,"material":"PLA","color":"#161616","idx":"GFL99","nozzle":"main"},
        \\{"slot":"A4","tray":3,"material":"PLA","color":"#f98c36","idx":"GFL99"},
        \\{"slot":"Ext","tray":255,"material":"PLA","color":"#f72323","idx":"GFL99","nozzle":"aux"}]}
    ;
    var changed: c_int = 0;
    try t.expectEqual(ok, zs_app_filaments_from_printer(a, "X2D", json.ptr, json.len, 1, &changed, null, 0));
    try t.expectEqual(@as(usize, 5), app_mod.filament_slots.count(a.?));
    try t.expectEqual(@as(u32, 1), app_mod.filament_slots.get(a.?, 4).?.nozzle);
    // The tray of each filament: filament 2 is A2 (tray 1), filament 5
    // the external spool (255).
    var map: [8]i32 = undefined;
    try t.expectEqual(@as(usize, 5), zs_app_ams_mapping(a, &map, map.len));
    try t.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 255 }, map[0..5]);
    // The print start: the external spool is -1 in ams_mapping and its
    // virtual tray in ams_mapping2.
    const start = try zs.bambu.startMessage(al, .{ .file = "p.gcode.3mf", .title = "p", .trays = map[0..5] });
    defer al.free(start);
    try t.expect(std.mem.indexOf(u8, start, "\"ams_mapping\":[0,1,2,3,-1],\"ams_mapping2\":[{\"ams_id\":0,\"slot_id\":0},{\"ams_id\":0,\"slot_id\":1},{\"ams_id\":0,\"slot_id\":2},{\"ams_id\":0,\"slot_id\":3},{\"ams_id\":255,\"slot_id\":0}]") != null);

    const Case = struct { filament: [:0]const u8, slot: u32, color: []const u8, info: []const u8 };
    const cases = [_]Case{
        .{ .filament = "2", .slot = 1, .color = "#dcdcdc", .info = "<filament id=\"2\" tray_info_idx=\"GFL99\" type=\"PLA\" color=\"#DCDCDC\"" },
        .{ .filament = "5", .slot = 4, .color = "#f72323", .info = "<filament id=\"5\" tray_info_idx=\"GFL99\" type=\"PLA\" color=\"#F72323\"" },
    };
    for (cases) |cs| {
        try t.expectEqual(ok, zs_app_part_setting_set(a, 0, "project.filament", cs.filament.ptr));
        try t.expectEqual(ok, zs_app_slice(a));
        a.?.stopWorkerForTest();
        // Each path, the support too (its filament is the part's), prints
        // with the filament of the part.
        const tp = a.?.allToolpaths().?;
        for (tp.path_tool.items) |tool| try t.expectEqual(cs.slot, tool);
        // The start loads it, and no other filament loads.
        const g = a.?.exactGcode().?;
        try t.expect(try expectLoads(g, cs.slot) >= 2);
        // The file for the printer: one filament, the one of the part, on
        // its nozzle.
        var out: ?[*]u8 = null;
        var len: usize = 0;
        try t.expectEqual(ok, zs_app_bambu_file(a, "p", &out, &len));
        defer gpa.free(out.?[0..len]);
        const entries = try zs.zipfile.readAll(al, out.?[0..len]);
        defer zs.zipfile.freeAll(al, entries);
        var info: []const u8 = "";
        for (entries) |e| if (std.mem.eql(u8, e.name, "Metadata/slice_info.config")) {
            info = e.data;
        };
        try t.expect(std.mem.indexOf(u8, info, cs.info) != null);
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, info, "<filament id="));
        if (cs.slot == 4) {
            try t.expect(std.mem.indexOf(u8, info, "group_id=\"1\"") != null);
            try t.expect(std.mem.indexOf(u8, info, "\"filament_maps\" value=\"1 1 1 1 2\"") != null);
        }
        // The view draws each bead of the print in that color.
        const vw = @import("view.zig");
        if (vw.render_on) {
            const scene = vw.view_mod.View.buildScene(a.?.sceneSource().?, 0).?;
            defer vw.view_mod.View.freeScene(scene);
            const v: *vw.view_mod.View = @ptrCast(@alignCast(scene));
            const want = zs.filaments.parseColor(cs.color).?;
            try t.expect(v.beads.items.len > 0);
            for (v.beads.items) |bd| if (bd.rgba[3] < 11) try t.expectEqualSlices(u8, &want, bd.rgba[0..3]);
        }
    }
}
