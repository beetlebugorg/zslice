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
        .moonraker => "/printer/objects/query?print_stats&virtual_sdcard&toolhead&configfile=settings",
        .bambu, .none => "",
    };
}

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
        }
    }
};

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

