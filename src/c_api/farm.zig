//! The C API of the farm (src/app/farm.zig): printers, orders, and jobs,
//! the proposals of sends, the state of the printers from the polls, and
//! the events (ready to collect, failed, paused, an order done or failed).
//! See zslice-app.h.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const ok = c.ok;
const gpa = c.gpa;
const farm_mod = zs.app.farm_mod;

/// The farm and the events of the last zs_farm_events.
const Handle = struct {
    farm: farm_mod.Farm,
    taken: std.ArrayList(farm_mod.Event) = .empty,
    /// The texts of `taken`, until the next zs_farm_events.
    texts: std.heap.ArenaAllocator,
};

/// zs_farm_send in zslice-app.h.
const CSend = extern struct { job: u32, printer: usize };

/// zs_farm_event in zslice-app.h.
const CEvent = extern struct {
    kind: c_int,
    job: u32,
    order: u32,
    printer: isize,
    text: [*]const u8,
    text_len: usize,
};

/// zs_farm_job in zslice-app.h.
const CJob = extern struct {
    id: u32,
    order: u32,
    state: c_int,
    tries: u32,
    printer: isize,
    progress: f64,
    seconds: f64,
    name: [*]const u8,
    name_len: usize,
};

/// zs_farm_printer in zslice-app.h.
const CPrinter = extern struct {
    state: c_int,
    progress: f64,
    /// The job on the printer, or 0.
    job: u32,
    key: [*]const u8,
    key_len: usize,
};

fn span(s: ?[*:0]const u8) []const u8 {
    return if (s) |x| std.mem.span(x) else "";
}

export fn zs_farm_new(out: ?*?*Handle) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const h = gpa.create(Handle) catch return @intFromEnum(Status.out_of_memory);
    h.* = .{ .farm = .init(gpa), .texts = .init(gpa) };
    o.* = h;
    return ok;
}

export fn zs_farm_free(h: ?*Handle) void {
    const x = h orelse return;
    x.farm.deinit();
    x.taken.deinit(gpa);
    x.texts.deinit();
    gpa.destroy(x);
}

/// Adds a printer, or changes its facts. Returns its index, or -status.
export fn zs_farm_printer_set(h: ?*Handle, key: ?[*:0]const u8, bed_x: f64, bed_y: f64, nozzle: f64, material: ?[*:0]const u8, printdeck: c_int) isize {
    const x = h orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const i = x.farm.setPrinter(span(key), bed_x, bed_y, nozzle, span(material), printdeck != 0) catch return -@as(isize, @intFromEnum(Status.out_of_memory));
    return @intCast(i);
}

/// The index of the printer with the key, or -1.
export fn zs_farm_printer_find(h: ?*Handle, key: ?[*:0]const u8) isize {
    const x = h orelse return -1;
    return if (x.farm.findPrinter(span(key))) |i| @intCast(i) else -1;
}

export fn zs_farm_printer_count(h: ?*Handle) usize {
    const x = h orelse return 0;
    return x.farm.printers.items.len;
}

export fn zs_farm_printer_get(h: ?*Handle, i: usize, out: ?*CPrinter) c_int {
    const x = h orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= x.farm.printers.items.len) return @intFromEnum(Status.out_of_range);
    const p = x.farm.printers.items[i];
    o.* = .{ .state = @intFromEnum(p.state), .progress = p.progress, .job = p.job orelse 0, .key = p.key.ptr, .key_len = p.key.len };
    return ok;
}

/// Adds an order. Returns its id (> 0), or -status.
export fn zs_farm_order_add(h: ?*Handle, customer: ?[*:0]const u8, due: i64) i64 {
    const x = h orelse return -@as(i64, @intFromEnum(Status.invalid_argument));
    return x.farm.addOrder(span(customer), due) catch -@as(i64, @intFromEnum(Status.out_of_memory));
}

/// Adds a job (one plate) to an order. Returns its id (> 0), or -status.
export fn zs_farm_job_add(h: ?*Handle, order: u32, name: ?[*:0]const u8, material: ?[*:0]const u8, bed_x: f64, bed_y: f64, nozzle: f64, seconds: f64) i64 {
    const x = h orelse return -@as(i64, @intFromEnum(Status.invalid_argument));
    return x.farm.addJob(order, span(name), span(material), bed_x, bed_y, nozzle, seconds) catch |e| switch (e) {
        error.OutOfMemory => -@as(i64, @intFromEnum(Status.out_of_memory)),
        error.NoOrder => -@as(i64, @intFromEnum(Status.out_of_range)),
    };
}

export fn zs_farm_job_count(h: ?*Handle) usize {
    const x = h orelse return 0;
    return x.farm.jobs.items.len;
}

export fn zs_farm_job_get(h: ?*Handle, i: usize, out: ?*CJob) c_int {
    const x = h orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= x.farm.jobs.items.len) return @intFromEnum(Status.out_of_range);
    const j = x.farm.jobs.items[i];
    o.* = .{
        .id = j.id,
        .order = j.order,
        .state = @intFromEnum(j.state),
        .tries = j.tries,
        .printer = if (j.printer) |p| @intCast(p) else -1,
        .progress = j.progress,
        .seconds = j.seconds,
        .name = j.name.ptr,
        .name_len = j.name.len,
    };
    return ok;
}

/// The state of printer i from a poll (enum zs_farm_printer_state), the
/// progress of its job (0 to 1), why it failed (or NULL), and the time
/// (any clock in seconds).
export fn zs_farm_status(h: ?*Handle, printer: usize, state: c_int, progress: f64, why: ?[*:0]const u8, now: i64) c_int {
    const x = h orelse return @intFromEnum(Status.invalid_argument);
    if (printer >= x.farm.printers.items.len) return @intFromEnum(Status.out_of_range);
    const st = std.enums.fromInt(farm_mod.PrinterState, state) orelse return @intFromEnum(Status.invalid_value);
    x.farm.status(printer, st, progress, span(why), now) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

/// Proposals: each waiting job to a free printer that fits it. They change
/// nothing; the app asks the person, sends, and calls zs_farm_sent.
/// Returns the count (at most cap).
export fn zs_farm_next(h: ?*Handle, out: ?[*]CSend, cap: usize) usize {
    const x = h orelse return 0;
    const o = out orelse return 0;
    const tmp = gpa.alloc(farm_mod.Send, cap) catch return 0;
    defer gpa.free(tmp);
    const n = x.farm.next(gpa, tmp) catch return 0;
    for (tmp[0..n], 0..) |s, i| o[i] = .{ .job = s.job, .printer = s.printer };
    return n;
}

/// The app sent the file of the job to printer i.
export fn zs_farm_sent(h: ?*Handle, job: u32, printer: usize, now: i64) c_int {
    const x = h orelse return @intFromEnum(Status.invalid_argument);
    x.farm.sent(job, printer, now) catch return @intFromEnum(Status.out_of_range);
    return ok;
}

/// A person took the print off printer i: the printer is free.
export fn zs_farm_collected(h: ?*Handle, printer: usize) c_int {
    const x = h orelse return @intFromEnum(Status.invalid_argument);
    if (printer >= x.farm.printers.items.len) return @intFromEnum(Status.out_of_range);
    x.farm.collected(printer);
    return ok;
}

/// Takes the events since the last call into out (at most cap; the
/// others are lost). The texts stay valid until the next call.
export fn zs_farm_events(h: ?*Handle, out: ?[*]CEvent, cap: usize) usize {
    const x = h orelse return 0;
    _ = x.texts.reset(.retain_capacity);
    x.farm.takeEvents(&x.taken) catch return 0;
    // The texts move to the handle; the farm frees its copies.
    for (x.taken.items) |*e| e.text = x.texts.allocator().dupe(u8, e.text) catch "";
    _ = x.farm.texts.reset(.retain_capacity);
    const o = out orelse return 0;
    const n = @min(cap, x.taken.items.len);
    for (x.taken.items[0..n], 0..) |e, i| o[i] = .{
        .kind = @intFromEnum(e.kind),
        .job = e.job,
        .order = e.order,
        .printer = e.printer,
        .text = e.text.ptr,
        .text_len = e.text.len,
    };
    return n;
}

test "C API: the farm" {
    var h: ?*Handle = null;
    try std.testing.expectEqual(ok, zs_farm_new(&h));
    defer zs_farm_free(h);
    const p = zs_farm_printer_set(h, "a", 220, 220, 0.4, "PLA", 0);
    try std.testing.expectEqual(@as(isize, 0), p);
    try std.testing.expectEqual(ok, zs_farm_status(h, 0, 1, 0, null, 0));
    const o = zs_farm_order_add(h, "Dee", 0);
    const j = zs_farm_job_add(h, @intCast(o), "box", "PLA", 50, 50, 0.4, 60);
    try std.testing.expect(j > 0);
    var sends: [4]CSend = undefined;
    try std.testing.expectEqual(@as(usize, 1), zs_farm_next(h, &sends, sends.len));
    try std.testing.expectEqual(ok, zs_farm_sent(h, sends[0].job, sends[0].printer, 1));
    try std.testing.expectEqual(ok, zs_farm_status(h, 0, 2, 0.5, null, 2));
    try std.testing.expectEqual(ok, zs_farm_status(h, 0, 5, 0.5, "Clog", 3));
    var ev: [4]CEvent = undefined;
    const n = zs_farm_events(h, &ev, ev.len);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(c_int, 1), ev[0].kind);
    try std.testing.expectEqualStrings("Clog", ev[0].text[0..ev[0].text_len]);
}
