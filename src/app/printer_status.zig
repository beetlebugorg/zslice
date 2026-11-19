//! The status of a printer from the replies of its API, for the printer
//! line of each app: the state, the job, the bed and the nozzle, the
//! filament and its rolls (printdeck), and the motion limits (printdeck).
//!
//! The app does the requests: it GETs each path of `paths(kind)` in order,
//! and gives each reply to `feed`. The kinds:
//!
//! - OctoPrint: /api/printer (the state), /api/printerprofiles (the bed and
//!   the nozzle of the current profile), /api/job (the job).
//! - printdeck: /api/printer (the state, as OctoPrint), and
//!   /api/plugin/printdeck (the material, the rolls, the limits, the job).
//! - Moonraker: /printer/objects/query with print_stats, virtual_sdcard,
//!   toolhead, and the extruder settings.
//! - Bambu Lab (LAN): no paths; each MQTT report of the printer (topic
//!   device/<serial>/report) goes to `feed` with the path "report".
//!
//! The temperatures come from the same replies: the "temperature" object of
//! /api/printer, the extruder and heater_bed objects of Moonraker, and the
//! *_temper fields of a Bambu Lab report.
//!
//! The camera of a printer comes from `cameraPaths(kind)`: the webcam of
//! the settings of OctoPrint and printdeck (/api/settings), and the webcam
//! list of Moonraker (/server/webcams/list). The status keeps the address
//! of the MJPEG stream (when the printer gives one), the address of the
//! snapshot, and the turn of the picture. The addresses can be relative to
//! the printer. A Bambu Lab printer has its camera on a port of its own
//! (see bambu.zig, `cameraOf`).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Kind = enum(u8) { none = 0, octoprint = 1, printdeck = 2, moonraker = 3, bambu = 4 };

/// The paths to GET for a kind, one on each line.
pub fn paths(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .octoprint => "/api/printer\n/api/printerprofiles\n/api/job",
        .printdeck => "/api/printer\n/api/plugin/printdeck",
        .moonraker => "/printer/objects/query?print_stats&virtual_sdcard&toolhead&extruder&heater_bed&configfile=settings",
        .bambu, .none => "",
    };
}

/// The paths to GET for the camera of a kind, one on each line. The
/// camera changes seldom: an app reads these once when it shows the
/// printer.
pub fn cameraPaths(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .octoprint, .printdeck => "/api/settings",
        .moonraker => "/server/webcams/list",
        .bambu, .none => "",
    };
}

/// The temperatures in °C, NaN when not known.
pub const Heat = struct {
    nozzle: f64 = std.math.nan(f64),
    nozzle_target: f64 = std.math.nan(f64),
    bed: f64 = std.math.nan(f64),
    bed_target: f64 = std.math.nan(f64),
    chamber: f64 = std.math.nan(f64),
};

/// The camera of a printer. The addresses are "" when not known, and can
/// be relative to the printer ("/webcam/?action=stream").
pub const Camera = struct {
    /// An MJPEG stream (multipart/x-mixed-replace), for an <img> or a
    /// reader of parts. "" when the printer gives only snapshots, or a
    /// stream of another format (WebRTC, HLS).
    stream: [:0]const u8 = "",
    /// One JPEG picture.
    snapshot: [:0]const u8 = "",
    flip_h: bool = false,
    flip_v: bool = false,
    /// The turn of the picture in degrees clockwise: 0, 90, 180, or 270.
    rotation: i32 = 0,
};

pub const Roll = struct {
    id: [:0]const u8 = "",
    name: [:0]const u8 = "",
    material: [:0]const u8 = "",
    color: [:0]const u8 = "",
    /// Grams left.
    left: f64 = 0,
};

/// The status. The strings are in the arena of the status.
pub const Status = struct {
    arena: std.heap.ArenaAllocator,
    /// "Operational", "Printing", "standby", and so on.
    state: [:0]const u8 = "",
    bed_x: f64 = 0,
    bed_y: f64 = 0,
    height: f64 = 0,
    nozzle: f64 = 0,
    /// The filament in the printer ("PLA"), and its diameter.
    material: [:0]const u8 = "",
    diameter: f64 = 0,
    /// The loaded roll.
    spool: Roll = .{},
    /// The price of the loaded roll, and the grams of a full roll; 0 when
    /// not known.
    spool_price: f64 = 0,
    spool_full: f64 = 0,
    /// All rolls of the printer.
    rolls: []Roll = &.{},
    /// The motion limits (mm/s, mm/s²), 0 when not known.
    max_velocity: f64 = 0,
    max_accel: f64 = 0,
    corner_velocity: f64 = 0,
    max_z_velocity: f64 = 0,
    max_z_accel: f64 = 0,
    /// The job: its title ("" for none), the progress 0 to 1, the seconds
    /// left (-1 when not known), and the layer and the layer count (0 when
    /// not known).
    job: [:0]const u8 = "",
    progress: f64 = 0,
    time_left: f64 = -1,
    layer: i32 = 0,
    layers: i32 = 0,
    /// Why the print failed or stopped, as the printer says it ("" for
    /// none): the error of OctoPrint and printdeck, the message of
    /// Moonraker, the error code of a Bambu Lab printer.
    message: [:0]const u8 = "",
    heat: Heat = .{},
    camera: Camera = .{},

    pub fn init(gpa: Allocator) Status {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(s: *Status) void {
        s.arena.deinit();
    }

    /// Reads the reply `body` of `path` for a printer of `kind`. A reply
    /// that is not JSON, or of another path, changes nothing.
    pub fn feed(s: *Status, kind: Kind, path: []const u8, body: []const u8) Allocator.Error!void {
        _ = kind;
        const a = s.arena.allocator();
        var parsed = std.json.parseFromSlice(Value, s.arena.child_allocator, body, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (std.mem.eql(u8, path, "/api/printer")) {
            if (try str(a, root, "state.text")) |t| s.state = t;
            setNum(&s.heat.nozzle, root, "temperature.tool0.actual");
            setNum(&s.heat.nozzle_target, root, "temperature.tool0.target");
            setNum(&s.heat.bed, root, "temperature.bed.actual");
            setNum(&s.heat.bed_target, root, "temperature.bed.target");
            setNum(&s.heat.chamber, root, "temperature.chamber.actual");
        } else if (std.mem.eql(u8, path, "/api/settings")) {
            try s.readOctoCamera(root);
        } else if (std.mem.eql(u8, path, "/server/webcams/list")) {
            try s.readMoonrakerCamera(get(root, "result.webcams") orelse return);
        } else if (std.mem.eql(u8, path, "/api/printerprofiles")) {
            const profiles = get(root, "profiles") orelse return;
            if (profiles != .object) return;
            var it = profiles.object.iterator();
            const many = profiles.object.count() > 1;
            while (it.next()) |e| {
                const prof = e.value_ptr.*;
                const cur = get(prof, "current");
                if (many and !(cur != null and cur.? == .bool and cur.?.bool)) continue;
                s.bed_x = num(prof, "volume.width");
                s.bed_y = num(prof, "volume.depth");
                s.height = num(prof, "volume.height");
                s.nozzle = num(prof, "extruder.nozzleDiameter");
                break;
            }
        } else if (std.mem.eql(u8, path, "/api/job")) {
            s.job = (try str(a, root, "job.file.display")) orelse (try str(a, root, "job.file.name")) orelse "";
            s.message = (try str(a, root, "error")) orelse (try str(a, root, "job.error")) orelse "";
            s.progress = num(root, "progress.completion") / 100;
            const left = get(root, "progress.printTimeLeft");
            s.time_left = if (left) |l| numOf(l) orelse -1 else -1;
        } else if (std.mem.eql(u8, path, "/api/plugin/printdeck")) {
            if (try str(a, root, "material")) |t| s.material = t;
            s.diameter = num(root, "diameter");
            s.spool = try rollOf(a, get(root, "spool"));
            s.spool_price = num(root, "spool.price");
            s.spool_full = num(root, "spool.full");
            s.max_velocity = num(root, "limits.max_velocity");
            s.max_accel = num(root, "limits.max_accel");
            s.corner_velocity = num(root, "limits.square_corner_velocity");
            s.max_z_velocity = num(root, "limits.max_z_velocity");
            s.max_z_accel = num(root, "limits.max_z_accel");
            if (get(root, "spools")) |list| if (list == .array) {
                const rolls = try a.alloc(Roll, list.array.items.len);
                for (list.array.items, rolls) |e, *r| r.* = try rollOf(a, e);
                s.rolls = rolls;
            };
            if (try str(a, root, "job.title")) |t| {
                s.job = t;
                if (try str(a, root, "job.state")) |st| s.state = st;
                s.progress = num(root, "job.progress");
                s.time_left = if (get(root, "job.left")) |l| numOf(l) orelse -1 else -1;
                s.layer = @intFromFloat(num(root, "job.layer"));
                s.layers = @intFromFloat(num(root, "job.layers"));
            }
        } else if (std.mem.eql(u8, path, "report")) {
            // A report of a Bambu Lab printer: a full report or a change.
            const p = get(root, "print") orelse return;
            if (try str(a, p, "gcode_state")) |t| s.state = t;
            if (try str(a, p, "subtask_name")) |t| s.job = t;
            if (get(p, "print_error")) |v| {
                const code: i64 = @intFromFloat(numOf(v) orelse 0);
                s.message = if (code != 0) try std.fmt.allocPrintSentinel(a, "Error code {X:0>8}", .{@as(u64, @bitCast(code))}, 0) else "";
            }
            if (get(p, "mc_percent")) |v| s.progress = (numOf(v) orelse 0) / 100;
            // Minutes.
            if (get(p, "mc_remaining_time")) |v| s.time_left = (numOf(v) orelse -1) * 60;
            if (get(p, "layer_num")) |v| s.layer = @intFromFloat(numOf(v) orelse 0);
            if (get(p, "total_layer_num")) |v| s.layers = @intFromFloat(numOf(v) orelse 0);
            if (get(p, "nozzle_diameter")) |v| s.nozzle = switch (v) {
                .string => |t| std.fmt.parseFloat(f64, t) catch 0,
                else => numOf(v) orelse 0,
            };
            setNum(&s.heat.nozzle, p, "nozzle_temper");
            setNum(&s.heat.nozzle_target, p, "nozzle_target_temper");
            setNum(&s.heat.bed, p, "bed_temper");
            setNum(&s.heat.bed_target, p, "bed_target_temper");
            setNum(&s.heat.chamber, p, "chamber_temper");
            // The printers with two nozzles (H2D, X2D) report each nozzle
            // in device.extruder.info: "temp" has the temperature in its
            // low 16 bits and the target in its high 16 bits, as the Home
            // Assistant integration ha-bambulab reads it. Bits 4 to 7 of
            // device.extruder.state are the nozzle in use. Not yet checked
            // with a real printer.
            if (get(p, "device.extruder.info")) |list| if (list == .array and list.array.items.len > 0) {
                const st: u32 = @intFromFloat(std.math.clamp(num(p, "device.extruder.state"), 0, 65535));
                const want: f64 = @floatFromInt((st >> 4) & 0xf);
                var pick = list.array.items[0];
                for (list.array.items) |e| {
                    if (num(e, "id") == want) pick = e;
                }
                if (get(pick, "temp")) |t| if (numOf(t)) |both| {
                    const bits: u32 = @intFromFloat(std.math.clamp(both, 0, 4294967295));
                    s.heat.nozzle = @floatFromInt(bits & 0xffff);
                    s.heat.nozzle_target = @floatFromInt(bits >> 16);
                };
            };
        } else if (std.mem.startsWith(u8, path, "/printer/objects/query")) {
            const st = get(root, "result.status") orelse return;
            if (try str(a, st, "print_stats.state")) |t| s.state = t;
            s.job = (try str(a, st, "print_stats.filename")) orelse "";
            s.message = (try str(a, st, "print_stats.message")) orelse "";
            s.progress = num(st, "virtual_sdcard.progress");
            if (get(st, "toolhead.axis_maximum")) |m| if (m == .array and m.array.items.len >= 3) {
                s.bed_x = numOf(m.array.items[0]) orelse 0;
                s.bed_y = numOf(m.array.items[1]) orelse 0;
                s.height = numOf(m.array.items[2]) orelse 0;
            };
            s.nozzle = num(st, "configfile.settings.extruder.nozzle_diameter");
            s.diameter = num(st, "configfile.settings.extruder.filament_diameter");
            setNum(&s.heat.nozzle, st, "extruder.temperature");
            setNum(&s.heat.nozzle_target, st, "extruder.target");
            setNum(&s.heat.bed, st, "heater_bed.temperature");
            setNum(&s.heat.bed_target, st, "heater_bed.target");
        }
    }

    /// The webcam of OctoPrint and printdeck (/api/settings): the classic
    /// streamUrl and snapshotUrl, or else the default camera of the
    /// webcams list of OctoPrint 1.9 and later. rotate90 turns the picture
    /// 90° counterclockwise.
    fn readOctoCamera(s: *Status, root: Value) Allocator.Error!void {
        const a = s.arena.allocator();
        const w = get(root, "webcam") orelse return;
        const on = get(w, "webcamEnabled");
        if (on != null and on.? == .bool and !on.?.bool) {
            s.camera = .{};
            return;
        }
        var cam: Camera = .{
            .stream = (try str(a, w, "streamUrl")) orelse "",
            .snapshot = (try str(a, w, "snapshotUrl")) orelse "",
            .flip_h = flag(w, "flipH"),
            .flip_v = flag(w, "flipV"),
            .rotation = if (flag(w, "rotate90")) 270 else 0,
        };
        if (cam.stream.len == 0 and cam.snapshot.len == 0) {
            if (get(w, "webcams")) |list| if (list == .array and list.array.items.len > 0) {
                const def = get(w, "defaultWebcam");
                var pick = list.array.items[0];
                for (list.array.items) |e| {
                    const n = get(e, "name") orelse continue;
                    if (def != null and def.? == .string and n == .string and std.mem.eql(u8, n.string, def.?.string)) pick = e;
                }
                cam = .{
                    .stream = (try str(a, pick, "compat.stream")) orelse "",
                    .snapshot = (try str(a, pick, "compat.snapshot")) orelse "",
                    .flip_h = flag(pick, "flipH"),
                    .flip_v = flag(pick, "flipV"),
                    .rotation = if (flag(pick, "rotate90")) 270 else 0,
                };
            };
        }
        s.camera = cam;
    }

    /// The first enabled webcam of Moonraker. Its stream_url is an MJPEG
    /// stream only for the services "mjpegstreamer" and "uv4l-mjpeg". The
    /// other services ("mjpegstreamer-adaptive", "webrtc-camerastreamer",
    /// "hlsstream", "ipstream") get the snapshot only.
    fn readMoonrakerCamera(s: *Status, list: Value) Allocator.Error!void {
        const a = s.arena.allocator();
        if (list != .array) return;
        s.camera = .{};
        for (list.array.items) |e| {
            const on = get(e, "enabled");
            if (on != null and on.? == .bool and !on.?.bool) continue;
            const service = get(e, "service");
            const mjpeg = service == null or (service.? == .string and
                (std.mem.eql(u8, service.?.string, "mjpegstreamer") or std.mem.eql(u8, service.?.string, "uv4l-mjpeg")));
            const rot = num(e, "rotation");
            s.camera = .{
                .stream = if (mjpeg) (try str(a, e, "stream_url")) orelse "" else "",
                .snapshot = (try str(a, e, "snapshot_url")) orelse "",
                .flip_h = flag(e, "flip_horizontal"),
                .flip_v = flag(e, "flip_vertical"),
                .rotation = if (rot == 90 or rot == 180 or rot == 270) @intFromFloat(rot) else 0,
            };
            return;
        }
    }
};

/// Sets `out` to the number at `path`, when there is one.
fn setNum(out: *f64, v: Value, path: []const u8) void {
    if (get(v, path)) |x| if (numOf(x)) |n| {
        out.* = n;
    };
}

fn flag(v: Value, path: []const u8) bool {
    const x = get(v, path) orelse return false;
    return x == .bool and x.bool;
}

/// The state of a printer for the farm (farm.zig, PrinterState), from the
/// state text of each kind of printer: OctoPrint and printdeck
/// ("Operational", "Printing", "Paused", "Error", "Offline"), Moonraker
/// ("standby", "printing", "paused", "complete", "cancelled", "error"),
/// and Bambu Lab ("IDLE", "PREPARE", "RUNNING", "PAUSE", "FINISH",
/// "FAILED"). 0 offline, 1 idle, 2 printing, 3 paused, 4 finished (the
/// print is still on the bed), 5 failed.
pub fn farmState(state: []const u8) u8 {
    if (state.len == 0) return 0;
    var low: [48]u8 = undefined;
    const t = std.ascii.lowerString(low[0..@min(state.len, low.len)], state[0..@min(state.len, low.len)]);
    const has = struct {
        fn f(x: []const u8, words: []const []const u8) bool {
            for (words) |w| if (std.mem.indexOf(u8, x, w) != null) return true;
            return false;
        }
    }.f;
    // "Offline after error" (OctoPrint) is a failure.
    if (has(t, &.{ "error", "fail", "cancel" })) return 5;
    if (has(t, &.{ "offline", "closed", "disconnect", "unknown" })) return 0;
    if (has(t, &.{ "pause" })) return 3;
    if (has(t, &.{ "finish", "complete" })) return 4;
    if (has(t, &.{ "print", "running", "prepare", "busy", "heating" })) return 2;
    return 1;
}

test "printer status: the state for the farm, and why it failed" {
    try std.testing.expectEqual(@as(u8, 1), farmState("Operational"));
    try std.testing.expectEqual(@as(u8, 2), farmState("Printing from SD"));
    try std.testing.expectEqual(@as(u8, 2), farmState("RUNNING"));
    try std.testing.expectEqual(@as(u8, 3), farmState("PAUSE"));
    try std.testing.expectEqual(@as(u8, 4), farmState("complete"));
    try std.testing.expectEqual(@as(u8, 5), farmState("Offline after error"));
    try std.testing.expectEqual(@as(u8, 0), farmState("Offline"));
    try std.testing.expectEqual(@as(u8, 1), farmState("standby"));
    var m: Status = .init(std.testing.allocator);
    defer m.deinit();
    try m.feed(.moonraker, "/printer/objects/query?print_stats", "{\"result\":{\"status\":{\"print_stats\":{\"state\":\"error\",\"filename\":\"x.gcode\",\"message\":\"Heater extruder not heating at expected rate\"}}}}");
    try std.testing.expectEqualStrings("Heater extruder not heating at expected rate", m.message);
}

fn rollOf(a: Allocator, v: ?Value) Allocator.Error!Roll {
    const e = v orelse return .{};
    return .{
        .id = (try str(a, e, "id")) orelse "",
        .name = (try str(a, e, "name")) orelse "",
        .material = (try str(a, e, "material")) orelse "",
        .color = (try str(a, e, "color")) orelse "",
        .left = num(e, "left"),
    };
}

/// The value at a dotted path ("job.file.name"), or null.
fn get(v: Value, path: []const u8) ?Value {
    var cur = v;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn numOf(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |t| std.fmt.parseFloat(f64, t) catch null,
        else => null,
    };
}

fn num(v: Value, path: []const u8) f64 {
    return numOf(get(v, path) orelse return 0) orelse 0;
}

fn str(a: Allocator, v: Value, path: []const u8) Allocator.Error!?[:0]const u8 {
    const x = get(v, path) orelse return null;
    if (x != .string) return null;
    return try a.dupeZ(u8, x.string);
}

const testing = std.testing;

test "printer status: OctoPrint" {
    var s = Status.init(testing.allocator);
    defer s.deinit();
    try s.feed(.octoprint, "/api/printer", "{\"state\":{\"text\":\"Printing\"}}");
    try s.feed(.octoprint, "/api/printerprofiles", "{\"profiles\":{\"a\":{\"current\":false,\"volume\":{\"width\":1}},\"b\":{\"current\":true,\"volume\":{\"width\":280,\"depth\":280,\"height\":250},\"extruder\":{\"nozzleDiameter\":0.5}}}}");
    try s.feed(.octoprint, "/api/job", "{\"job\":{\"file\":{\"name\":\"a.gcode\",\"display\":\"Part A\"}},\"progress\":{\"completion\":42.5,\"printTimeLeft\":600}}");
    try testing.expectEqualStrings("Printing", s.state);
    try testing.expectEqual(@as(f64, 280), s.bed_x);
    try testing.expectEqual(@as(f64, 0.5), s.nozzle);
    try testing.expectEqualStrings("Part A", s.job);
    try testing.expectApproxEqAbs(@as(f64, 0.425), s.progress, 1e-9);
    try testing.expectEqual(@as(f64, 600), s.time_left);
}

test "printer status: printdeck and Moonraker" {
    var s = Status.init(testing.allocator);
    defer s.deinit();
    try s.feed(.printdeck, "/api/plugin/printdeck", "{\"material\":\"PLA\",\"diameter\":2.85,\"spool\":{\"name\":\"Black\",\"id\":\"roll-4\",\"color\":\"#000000\",\"left\":512.5,\"price\":25,\"full\":1000},\"limits\":{\"max_velocity\":300,\"max_accel\":1500},\"spools\":[{\"name\":\"Black\",\"material\":\"PLA\",\"id\":\"roll-4\"},{\"name\":\"Navy\",\"material\":\"PLA\",\"id\":\"roll-3\"}],\"job\":{\"title\":\"Slate frame\",\"state\":\"Printing\",\"progress\":0.5,\"left\":3600,\"layer\":20,\"layers\":670}}");
    try testing.expectEqualStrings("roll-4", s.spool.id);
    try testing.expectEqual(@as(f64, 512.5), s.spool.left);
    try testing.expectEqual(@as(usize, 2), s.rolls.len);
    try testing.expectEqualStrings("Navy", s.rolls[1].name);
    try testing.expectEqual(@as(f64, 1500), s.max_accel);
    try testing.expectEqual(@as(i32, 670), s.layers);
    try testing.expectEqualStrings("Printing", s.state);
    var m = Status.init(testing.allocator);
    defer m.deinit();
    try m.feed(.moonraker, "/printer/objects/query?print_stats", "{\"result\":{\"status\":{\"print_stats\":{\"state\":\"printing\",\"filename\":\"x.gcode\"},\"virtual_sdcard\":{\"progress\":0.25},\"toolhead\":{\"axis_maximum\":[235,235,250,0]},\"configfile\":{\"settings\":{\"extruder\":{\"nozzle_diameter\":0.4,\"filament_diameter\":1.75}}}}}}");
    try testing.expectEqualStrings("printing", m.state);
    try testing.expectEqual(@as(f64, 235), m.bed_x);
    try testing.expectEqual(@as(f64, 1.75), m.diameter);
    // Not JSON: no change.
    try m.feed(.moonraker, "/printer/objects/query", "<html>");
    try testing.expectEqualStrings("printing", m.state);
}

test "printer status: a Bambu Lab report" {
    var s = Status.init(testing.allocator);
    defer s.deinit();
    try s.feed(.bambu, "report", "{\"print\":{\"gcode_state\":\"RUNNING\",\"subtask_name\":\"Benchy\",\"mc_percent\":42,\"mc_remaining_time\":65,\"layer_num\":20,\"total_layer_num\":239,\"nozzle_diameter\":\"0.4\"}}");
    try testing.expectEqualStrings("RUNNING", s.state);
    try testing.expectEqualStrings("Benchy", s.job);
    try testing.expectEqual(@as(f64, 3900), s.time_left);
    try testing.expectEqual(@as(i32, 239), s.layers);
    try testing.expectEqual(@as(f64, 0.4), s.nozzle);
    // A change report keeps the rest.
    try s.feed(.bambu, "report", "{\"print\":{\"mc_percent\":43}}");
    try testing.expectEqualStrings("Benchy", s.job);
    try testing.expectApproxEqAbs(@as(f64, 0.43), s.progress, 1e-9);
}


test "printer status: the temperatures" {
    var s = Status.init(testing.allocator);
    defer s.deinit();
    try testing.expect(std.math.isNan(s.heat.nozzle));
    try s.feed(.octoprint, "/api/printer", "{\"state\":{\"text\":\"Printing\"},\"temperature\":{\"tool0\":{\"actual\":214.8,\"target\":215},\"bed\":{\"actual\":59.9,\"target\":60}}}");
    try testing.expectEqual(@as(f64, 214.8), s.heat.nozzle);
    try testing.expectEqual(@as(f64, 60), s.heat.bed_target);
    try testing.expect(std.math.isNan(s.heat.chamber));
    var m = Status.init(testing.allocator);
    defer m.deinit();
    try m.feed(.moonraker, "/printer/objects/query", "{\"result\":{\"status\":{\"extruder\":{\"temperature\":200.5,\"target\":200},\"heater_bed\":{\"temperature\":55,\"target\":55}}}}");
    try testing.expectEqual(@as(f64, 200.5), m.heat.nozzle);
    try testing.expectEqual(@as(f64, 55), m.heat.bed);
    var b = Status.init(testing.allocator);
    defer b.deinit();
    try b.feed(.bambu, "report", "{\"print\":{\"nozzle_temper\":219.5,\"nozzle_target_temper\":220,\"bed_temper\":65,\"bed_target_temper\":65,\"chamber_temper\":31}}");
    try testing.expectEqual(@as(f64, 219.5), b.heat.nozzle);
    try testing.expectEqual(@as(f64, 31), b.heat.chamber);
    // A change report keeps the other temperatures.
    try b.feed(.bambu, "report", "{\"print\":{\"bed_temper\":66}}");
    try testing.expectEqual(@as(f64, 66), b.heat.bed);
    try testing.expectEqual(@as(f64, 219.5), b.heat.nozzle);
    // Two nozzles: nozzle 1 in use, 250 °C now, target 260.
    try b.feed(.bambu, "report", "{\"print\":{\"device\":{\"extruder\":{\"state\":16,\"info\":[{\"id\":0,\"temp\":30},{\"id\":1,\"temp\":17039610}]}}}}");
    try testing.expectEqual(@as(f64, 250), b.heat.nozzle);
    try testing.expectEqual(@as(f64, 260), b.heat.nozzle_target);
}

test "printer status: the camera" {
    var s = Status.init(testing.allocator);
    defer s.deinit();
    try s.feed(.printdeck, "/api/settings", "{\"webcam\":{\"webcamEnabled\":true,\"streamUrl\":\"/webcam/stream?apikey=k\",\"snapshotUrl\":\"/webcam/snapshot?apikey=k\",\"flipH\":false,\"rotate90\":true}}");
    try testing.expectEqualStrings("/webcam/stream?apikey=k", s.camera.stream);
    try testing.expectEqual(@as(i32, 270), s.camera.rotation);
    try s.feed(.octoprint, "/api/settings", "{\"webcam\":{\"webcamEnabled\":false,\"streamUrl\":\"/x\"}}");
    try testing.expectEqualStrings("", s.camera.stream);
    // OctoPrint 1.9: the webcams list.
    try s.feed(.octoprint, "/api/settings", "{\"webcam\":{\"streamUrl\":\"\",\"defaultWebcam\":\"b\",\"webcams\":[{\"name\":\"a\",\"compat\":{\"stream\":\"/a\"}},{\"name\":\"b\",\"flipV\":true,\"compat\":{\"stream\":\"/b\",\"snapshot\":\"/b.jpg\"}}]}}");
    try testing.expectEqualStrings("/b", s.camera.stream);
    try testing.expect(s.camera.flip_v);
    var m = Status.init(testing.allocator);
    defer m.deinit();
    try m.feed(.moonraker, "/server/webcams/list", "{\"result\":{\"webcams\":[{\"name\":\"off\",\"enabled\":false,\"service\":\"mjpegstreamer\",\"stream_url\":\"/no\"},{\"name\":\"cam\",\"enabled\":true,\"service\":\"webrtc-camerastreamer\",\"stream_url\":\"/webcam/webrtc\",\"snapshot_url\":\"/webcam/?action=snapshot\",\"rotation\":180}]}}");
    try testing.expectEqualStrings("", m.camera.stream);
    try testing.expectEqualStrings("/webcam/?action=snapshot", m.camera.snapshot);
    try testing.expectEqual(@as(i32, 180), m.camera.rotation);
    try testing.expectEqualStrings("/server/webcams/list", cameraPaths(.moonraker));
}
