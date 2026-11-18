//! The farm: printers, orders, and the jobs of the orders, for a shop that
//! runs many printers (specs: the farm). The apps poll each printer
//! (zs_printer_status) and give the core its state; the core keeps the
//! jobs, proposes which job goes to which printer, and says when a print
//! is ready to collect or failed.
//!
//! - A job is one plate to print: its name, its material, the bed it
//!   needs, its nozzle, and its time. It belongs to an order.
//! - `next` proposes sends: each waiting job (the oldest order first) to a
//!   free printer that fits it (bed, nozzle, material), the smallest bed
//!   first, so that the large printers stay free for large plates. A
//!   proposal changes nothing. The app asks the person ("Is the bed
//!   clear?"), sends the file, and calls `sent`.
//! - A printdeck starts a print only after a press of Print on its screen.
//!   A job sent to a printdeck waits in its queue ("sent") until the deck
//!   prints it. The core never starts a print by itself.
//! - `status` takes the state of a printer from a poll. A job on it goes
//!   printing, done (ready to collect), or failed, with an event each. A
//!   poll can miss a short state: when the job of a printer is gone and
//!   the printer is idle, a job that was near its end is done, and else it
//!   failed.
//! - A failed job goes back to waiting, at most `max_tries` times; then
//!   its order fails.
//! - A done job keeps its printer until a person collects the print
//!   (`collected`), or until the printer is idle again (the bed was
//!   cleared at the printer).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PrinterState = enum(u8) { offline = 0, idle = 1, printing = 2, paused = 3, finished = 4, failed = 5 };

pub const JobState = enum(u8) { waiting = 0, sent = 1, printing = 2, done = 3, collected = 4, failed = 5 };

pub const EventKind = enum(u8) {
    /// A print is done: collect it from the printer.
    ready = 0,
    /// A print failed (the text says why). The job waits again, or its
    /// order failed.
    failed = 1,
    /// A print paused (for example a filament runout).
    paused = 2,
    /// All jobs of an order are done.
    order_done = 3,
    /// A job of an order failed too often.
    order_failed = 4,
};

pub const Printer = struct {
    key: []u8,
    bed_x: f64 = 0,
    bed_y: f64 = 0,
    nozzle: f64 = 0,
    material: []u8 = &.{},
    /// A printdeck: a print starts only with a press on its screen.
    printdeck: bool = false,
    state: PrinterState = .offline,
    progress: f64 = 0,
    /// The job on the printer (sent, printing, or done), or none.
    job: ?u32 = null,
};

pub const Job = struct {
    id: u32,
    order: u32,
    name: []u8,
    material: []u8 = &.{},
    bed_x: f64 = 0,
    bed_y: f64 = 0,
    nozzle: f64 = 0,
    seconds: f64 = 0,
    state: JobState = .waiting,
    /// The printer of the job, while it is sent, printing, or done.
    printer: ?usize = null,
    tries: u32 = 0,
    /// The progress at the last poll, and the time of that poll, for a
    /// print that a poll missed.
    progress: f64 = 0,
    progress_at: i64 = 0,
    sent_at: i64 = 0,
    done_at: i64 = 0,
};

pub const Order = struct {
    id: u32,
    customer: []u8,
    due: i64 = 0,
    failed: bool = false,
    done: bool = false,
};

pub const Event = struct {
    kind: EventKind,
    job: u32 = 0,
    order: u32 = 0,
    /// The printer, or -1.
    printer: isize = -1,
    /// Why (a failure), in `Farm.texts`.
    text: []const u8 = "",
};

pub const Send = struct { job: u32, printer: usize };

pub const Farm = struct {
    gpa: Allocator,
    printers: std.ArrayList(Printer) = .empty,
    jobs: std.ArrayList(Job) = .empty,
    orders: std.ArrayList(Order) = .empty,
    events: std.ArrayList(Event) = .empty,
    /// The texts of the events, freed when the events are read.
    texts: std.heap.ArenaAllocator,
    max_tries: u32 = 3,
    /// A job whose printer went idle with no job is done if its progress
    /// was at least this at the last poll.
    near_end: f64 = 0.95,
    next_id: u32 = 1,

    pub fn init(gpa: Allocator) Farm {
        return .{ .gpa = gpa, .texts = .init(gpa) };
    }

    pub fn deinit(f: *Farm) void {
        for (f.printers.items) |p| {
            f.gpa.free(p.key);
            f.gpa.free(p.material);
        }
        for (f.jobs.items) |j| {
            f.gpa.free(j.name);
            f.gpa.free(j.material);
        }
        for (f.orders.items) |o| f.gpa.free(o.customer);
        f.printers.deinit(f.gpa);
        f.jobs.deinit(f.gpa);
        f.orders.deinit(f.gpa);
        f.events.deinit(f.gpa);
        f.texts.deinit();
    }

    pub fn findPrinter(f: *const Farm, key: []const u8) ?usize {
        for (f.printers.items, 0..) |p, i| if (std.mem.eql(u8, p.key, key)) return i;
        return null;
    }

    pub fn findJob(f: *const Farm, id: u32) ?usize {
        for (f.jobs.items, 0..) |j, i| if (j.id == id) return i;
        return null;
    }

    fn findOrder(f: *const Farm, id: u32) ?usize {
        for (f.orders.items, 0..) |o, i| if (o.id == id) return i;
        return null;
    }

    /// Adds a printer, or changes its facts (the state stays).
    pub fn setPrinter(f: *Farm, key: []const u8, bed_x: f64, bed_y: f64, nozzle: f64, material: []const u8, printdeck: bool) Allocator.Error!usize {
        const mat = try f.gpa.dupe(u8, material);
        errdefer f.gpa.free(mat);
        if (f.findPrinter(key)) |i| {
            const p = &f.printers.items[i];
            f.gpa.free(p.material);
            p.* = .{ .key = p.key, .bed_x = bed_x, .bed_y = bed_y, .nozzle = nozzle, .material = mat, .printdeck = printdeck, .state = p.state, .progress = p.progress, .job = p.job };
            return i;
        }
        const k = try f.gpa.dupe(u8, key);
        errdefer f.gpa.free(k);
        try f.printers.append(f.gpa, .{ .key = k, .bed_x = bed_x, .bed_y = bed_y, .nozzle = nozzle, .material = mat, .printdeck = printdeck });
        return f.printers.items.len - 1;
    }

    pub fn addOrder(f: *Farm, customer: []const u8, due: i64) Allocator.Error!u32 {
        const c = try f.gpa.dupe(u8, customer);
        errdefer f.gpa.free(c);
        const id = f.next_id;
        try f.orders.append(f.gpa, .{ .id = id, .customer = c, .due = due });
        f.next_id += 1;
        return id;
    }

    pub fn addJob(f: *Farm, order: u32, name: []const u8, material: []const u8, bed_x: f64, bed_y: f64, nozzle: f64, seconds: f64) (Allocator.Error || error{NoOrder})!u32 {
        if (f.findOrder(order) == null) return error.NoOrder;
        const n = try f.gpa.dupe(u8, name);
        errdefer f.gpa.free(n);
        const m = try f.gpa.dupe(u8, material);
        errdefer f.gpa.free(m);
        const id = f.next_id;
        try f.jobs.append(f.gpa, .{ .id = id, .order = order, .name = n, .material = m, .bed_x = bed_x, .bed_y = bed_y, .nozzle = nozzle, .seconds = seconds });
        f.next_id += 1;
        return id;
    }

    fn fits(p: *const Printer, j: *const Job) bool {
        // A plate fits a bed turned by 90 degrees too.
        const straight = p.bed_x + 0.01 >= j.bed_x and p.bed_y + 0.01 >= j.bed_y;
        const turned = p.bed_x + 0.01 >= j.bed_y and p.bed_y + 0.01 >= j.bed_x;
        if (p.bed_x > 0 and !(straight or turned)) return false;
        if (j.nozzle > 0 and p.nozzle > 0 and @abs(j.nozzle - p.nozzle) > 0.01) return false;
        if (j.material.len > 0 and p.material.len > 0 and !std.ascii.eqlIgnoreCase(j.material, p.material)) return false;
        return true;
    }

    fn free(p: *const Printer) bool {
        return p.state == .idle and p.job == null;
    }

    /// Proposes sends: each waiting job (the oldest order first, then the
    /// order of the jobs) to a free printer that fits it, the smallest bed
    /// first. Each printer and each job is in one proposal at most.
    /// Returns the count (at most out.len).
    pub fn next(f: *const Farm, gpa: Allocator, out: []Send) Allocator.Error!usize {
        const jobs = f.jobs.items;
        const used = try gpa.alloc(bool, f.printers.items.len);
        defer gpa.free(used);
        @memset(used, false);
        // The waiting jobs by the due time of their order (no due time:
        // last), then in the order they came.
        const Wait = struct { i: usize, due: i64 };
        var wait: std.ArrayList(Wait) = .empty;
        defer wait.deinit(gpa);
        for (jobs, 0..) |j, i| {
            if (j.state != .waiting) continue;
            const oi = f.findOrder(j.order);
            const due = if (oi) |x| f.orders.items[x].due else 0;
            try wait.append(gpa, .{ .i = i, .due = if (due != 0) due else std.math.maxInt(i64) });
        }
        std.sort.block(Wait, wait.items, {}, struct {
            fn lt(_: void, x: Wait, y: Wait) bool {
                return x.due < y.due or (x.due == y.due and x.i < y.i);
            }
        }.lt);
        var n: usize = 0;
        for (wait.items) |w| {
            if (n >= out.len) break;
            const j = &jobs[w.i];
            var best_p: ?usize = null;
            for (f.printers.items, 0..) |*p, pi| {
                if (used[pi] or !free(p) or !fits(p, j)) continue;
                if (best_p == null or p.bed_x * p.bed_y < f.printers.items[best_p.?].bed_x * f.printers.items[best_p.?].bed_y) best_p = pi;
            }
            const pi = best_p orelse continue;
            used[pi] = true;
            out[n] = .{ .job = j.id, .printer = pi };
            n += 1;
        }
        return n;
    }

    /// The app sent the file of a job to a printer (after the person said
    /// that the bed is clear).
    pub fn sent(f: *Farm, job: u32, printer: usize, now: i64) error{ NoJob, NoPrinter }!void {
        const ji = f.findJob(job) orelse return error.NoJob;
        if (printer >= f.printers.items.len) return error.NoPrinter;
        const j = &f.jobs.items[ji];
        // A job sent again (after a failure) leaves its old printer.
        if (j.printer) |old| if (f.printers.items[old].job == job) {
            f.printers.items[old].job = null;
        };
        j.state = .sent;
        j.printer = printer;
        j.sent_at = now;
        j.progress = 0;
        f.printers.items[printer].job = job;
    }

    /// A person took the print off the printer: the printer is free.
    pub fn collected(f: *Farm, printer: usize) void {
        if (printer >= f.printers.items.len) return;
        const p = &f.printers.items[printer];
        if (p.job) |id| if (f.findJob(id)) |ji| {
            const j = &f.jobs.items[ji];
            if (j.state == .done) j.state = .collected;
            j.printer = null;
        };
        p.job = null;
    }

    fn event(f: *Farm, kind: EventKind, j: ?*const Job, printer: isize, text: []const u8) Allocator.Error!void {
        const t = try f.texts.allocator().dupe(u8, text);
        try f.events.append(f.gpa, .{ .kind = kind, .job = if (j) |x| x.id else 0, .order = if (j) |x| x.order else 0, .printer = printer, .text = t });
    }

    fn jobDone(f: *Farm, j: *Job, pi: usize, now: i64) Allocator.Error!void {
        j.state = .done;
        j.done_at = now;
        try f.event(.ready, j, @intCast(pi), "");
        try f.checkOrder(j.order);
    }

    fn jobFailed(f: *Farm, j: *Job, pi: usize, why: []const u8) Allocator.Error!void {
        j.tries += 1;
        try f.event(.failed, j, @intCast(pi), why);
        f.printers.items[pi].job = null;
        j.printer = null;
        if (j.tries >= f.max_tries) {
            j.state = .failed;
            if (f.findOrder(j.order)) |oi| {
                const o = &f.orders.items[oi];
                if (!o.failed) {
                    o.failed = true;
                    try f.event(.order_failed, j, -1, why);
                }
            }
        } else {
            j.state = .waiting;
        }
    }

    fn checkOrder(f: *Farm, order: u32) Allocator.Error!void {
        const oi = f.findOrder(order) orelse return;
        const o = &f.orders.items[oi];
        if (o.done or o.failed) return;
        var any = false;
        for (f.jobs.items) |j| if (j.order == order) {
            any = true;
            if (j.state != .done and j.state != .collected) return;
        };
        if (!any) return;
        o.done = true;
        try f.events.append(f.gpa, .{ .kind = .order_done, .order = order });
    }

    /// The state of a printer from a poll: its state, the progress of its
    /// job (0 to 1), and why it failed (or ""). The job on the printer
    /// follows, with an event for each change.
    pub fn status(f: *Farm, printer: usize, state: PrinterState, progress: f64, why: []const u8, now: i64) Allocator.Error!void {
        if (printer >= f.printers.items.len) return;
        const p = &f.printers.items[printer];
        const before = p.state;
        p.state = state;
        p.progress = progress;
        const id = p.job orelse return;
        const ji = f.findJob(id) orelse {
            p.job = null;
            return;
        };
        const j = &f.jobs.items[ji];
        switch (state) {
            .printing => {
                j.state = .printing;
                j.progress = progress;
                j.progress_at = now;
            },
            .paused => {
                if (before != .paused) try f.event(.paused, j, @intCast(printer), why);
            },
            .finished => if (j.state == .sent or j.state == .printing) try f.jobDone(j, printer, now),
            .failed => if (j.state == .sent or j.state == .printing) try f.jobFailed(j, printer, if (why.len > 0) why else "The printer stopped with an error."),
            .idle => switch (j.state) {
                // A poll missed the end of the print: done near its end,
                // else it stopped.
                .printing => if (j.progress >= f.near_end or f.hadTime(j, now)) {
                    try f.jobDone(j, printer, now);
                    // Idle: the bed was cleared at the printer.
                    f.collected(printer);
                } else try f.jobFailed(j, printer, "The print stopped before its end."),
                // Idle after done: a person cleared the bed.
                .done => f.collected(printer),
                // A printdeck holds a sent job in its queue until a press.
                else => {},
            },
            .offline => {},
        }
    }

    /// True if the time since the last poll that saw the job print is
    /// enough for the rest of it (90 % of the rest of its time): a short
    /// print can end and be cleared between two polls.
    fn hadTime(f: *const Farm, j: *const Job, now: i64) bool {
        _ = f;
        if (j.seconds <= 0) return false;
        const rest = j.seconds * (1 - std.math.clamp(j.progress, 0, 1));
        return @as(f64, @floatFromInt(now - j.progress_at)) >= 0.9 * rest;
    }

    /// Takes the events since the last call. The texts stay valid until
    /// the next call.
    pub fn takeEvents(f: *Farm, out: *std.ArrayList(Event)) Allocator.Error!void {
        out.clearRetainingCapacity();
        try out.appendSlice(f.gpa, f.events.items);
        f.events.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "farm: jobs go to printers that fit, the smallest bed first" {
    var f = Farm.init(testing.allocator);
    defer f.deinit();
    const big = try f.setPrinter("big", 300, 300, 0.4, "PLA", false);
    const small = try f.setPrinter("small", 180, 180, 0.4, "PLA", false);
    const petg = try f.setPrinter("petg", 250, 250, 0.4, "PETG", false);
    for ([_]usize{ big, small, petg }) |p| try f.status(p, .idle, 0, "", 0);
    const o = try f.addOrder("Ann", 100);
    const j1 = try f.addJob(o, "clip", "PLA", 100, 100, 0.4, 600);
    const j2 = try f.addJob(o, "tray", "PLA", 280, 200, 0.4, 3600);
    var out: [8]Send = undefined;
    const n = try f.next(testing.allocator, &out);
    try testing.expectEqual(@as(usize, 2), n);
    // The clip goes to the small printer, the tray to the big one.
    try testing.expectEqual(j1, out[0].job);
    try testing.expectEqual(small, out[0].printer);
    try testing.expectEqual(j2, out[1].job);
    try testing.expectEqual(big, out[1].printer);
}

test "farm: a print goes sent, printing, done; a missed end is found" {
    var f = Farm.init(testing.allocator);
    defer f.deinit();
    const a = try f.setPrinter("a", 220, 220, 0.4, "", false);
    const deck = try f.setPrinter("deck", 220, 220, 0.4, "", true);
    try f.status(a, .idle, 0, "", 0);
    try f.status(deck, .idle, 0, "", 0);
    const o = try f.addOrder("Bo", 0);
    const j1 = try f.addJob(o, "one", "", 50, 50, 0, 60);
    const j2 = try f.addJob(o, "two", "", 50, 50, 0, 60);
    try f.sent(j1, a, 1);
    try f.sent(j2, deck, 1);
    var ev: std.ArrayList(Event) = .empty;
    defer ev.deinit(testing.allocator);
    // The deck holds the job in its queue: idle, with no event.
    try f.status(deck, .idle, 0, "", 2);
    try testing.expectEqual(JobState.sent, f.jobs.items[1].state);
    // Printer a prints, then a poll finds it idle at 97 %: done, and the
    // bed was cleared.
    try f.status(a, .printing, 0.97, "", 3);
    try f.status(a, .idle, 0, "", 4);
    try testing.expectEqual(JobState.collected, f.jobs.items[0].state);
    try f.takeEvents(&ev);
    try testing.expectEqual(@as(usize, 1), ev.items.len);
    try testing.expectEqual(EventKind.ready, ev.items[0].kind);
    // The deck prints after the press, and finishes: ready, and the order
    // is done.
    try f.status(deck, .printing, 0.5, "", 5);
    try f.status(deck, .finished, 1, "", 6);
    try f.takeEvents(&ev);
    try testing.expectEqual(@as(usize, 2), ev.items.len);
    try testing.expectEqual(EventKind.order_done, ev.items[1].kind);
    // The deck keeps the print until it is collected.
    var out: [4]Send = undefined;
    try testing.expectEqual(@as(usize, 0), try f.next(testing.allocator, &out));
    f.collected(deck);
    try f.status(deck, .idle, 0, "", 7);
    try testing.expect(Farm.free(&f.printers.items[deck]));
}

test "farm: a failed job waits again, and its order fails after the last try" {
    var f = Farm.init(testing.allocator);
    defer f.deinit();
    f.max_tries = 2;
    const a = try f.setPrinter("a", 220, 220, 0.4, "", false);
    try f.status(a, .idle, 0, "", 0);
    const o = try f.addOrder("Cy", 0);
    const j = try f.addJob(o, "vase", "", 50, 50, 0, 60);
    var ev: std.ArrayList(Event) = .empty;
    defer ev.deinit(testing.allocator);
    try f.sent(j, a, 1);
    try f.status(a, .printing, 0.3, "", 2);
    try f.status(a, .failed, 0.3, "Spaghetti", 3);
    try testing.expectEqual(JobState.waiting, f.jobs.items[0].state);
    try f.takeEvents(&ev);
    try testing.expectEqualStrings("Spaghetti", ev.items[0].text);
    // A print that stops halfway, with no error: a failure too.
    try f.status(a, .idle, 0, "", 4);
    try f.sent(j, a, 5);
    try f.status(a, .printing, 0.4, "", 6);
    try f.status(a, .idle, 0, "", 7);
    try testing.expectEqual(JobState.failed, f.jobs.items[0].state);
    try f.takeEvents(&ev);
    try testing.expectEqual(EventKind.order_failed, ev.items[ev.items.len - 1].kind);
}

test "farm: a short print that ends between two polls is done" {
    var f = Farm.init(testing.allocator);
    defer f.deinit();
    const deck = try f.setPrinter("deck", 220, 220, 0.4, "", true);
    try f.status(deck, .idle, 0, "", 0);
    const o = try f.addOrder("Eve", 0);
    // A 10 minute print.
    const j = try f.addJob(o, "clip", "", 50, 50, 0, 600);
    try f.sent(j, deck, 0);
    try f.status(deck, .printing, 0.1, "", 100);
    // 15 minutes later the deck is idle: the print had the time to end.
    try f.status(deck, .idle, 0, "", 1000);
    try testing.expectEqual(JobState.collected, f.jobs.items[0].state);
    // A second print that stops after one minute of ten is a failure.
    const k = try f.addJob(o, "box", "", 50, 50, 0, 600);
    try f.sent(k, deck, 1000);
    try f.status(deck, .printing, 0.1, "", 1010);
    try f.status(deck, .idle, 0, "", 1070);
    try testing.expectEqual(JobState.waiting, f.jobs.items[1].state);
}
