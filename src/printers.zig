//! The printer library: the printers that zslice knows, by brand and
//! model, with their beds, nozzles, motion, firmware, and G-code.
//!
//! The data comes from the printer definitions of Cura (LGPL-3.0-or-later),
//! PrusaSlicer (AGPL-3.0), and OrcaSlicer (AGPL-3.0). The tool
//! tools/printer_library.py converts them into one text file,
//! src/printers/library.txt. The core does no file I/O, so a shell gives the
//! bytes of the file to `Library.parse`. Native builds also embed the file
//! (`builtin_data`); the wasm module does not, so the web app loads the
//! file only when the user opens the printer picker.
//!
//! The format: one record on each line, with fields that tabs separate.
//!
//!     zslice-printers 1                   the first line
//!     # text                              a comment
//!     S  key  name  license  url  version a source of the data
//!     G  text                             a G-code text, with \n, \t, \\
//!     D  mesh texture offset rect source  a bed model (see below)
//!     B  brand                            a brand: the P lines after it
//!     P  id name series sources bed_x bed_y height origin_x origin_y
//!        shape nozzle nozzles filament heat max_speed max_accel max_z_speed
//!        corner flavor firmware kinematics retract retract_speed start end
//!        extruders bed
//!
//! In a P line: `sources` has one letter for each source (c Cura,
//! p PrusaSlicer, o OrcaSlicer). `shape` is "r" for a round bed.
//! `nozzles` lists the nozzle sizes with ";". `heat` has "b" for a heated
//! bed and "c" for a heated chamber. `max_speed` is the speed limit of the
//! firmware. `start` and `end` are the numbers of G lines (from 0), or "".
//! An empty number field means that the source does not tell the value.
//! `bed` is the number of a D line (from 0), or "": no bed model.
//!
//! A D line names the files of a bed model in the bed folder (`mesh` and
//! `texture`, each can be ""), the offset of the mesh from the center of
//! the bed ("x;y;z" in mm), the box of the texture from the center of the
//! bed ("x0;y0;x1;y1", or "" when the mesh has UV coordinates), and the
//! source key. See bed.zig for the files. The files are not in the
//! library: a shell loads them when it shows the bed.
//!
//! A machine profile of a model (`profileText`) uses the values of the
//! library, and these choices of zslice:
//!
//! - The speeds of a project are ratios of `machine.max_speed`, so
//!   `max_speed` is a print speed, not the limit of the firmware. It
//!   follows the acceleration: a printer with a higher acceleration prints
//!   faster (see `printSpeed`).
//! - A model with no G-code that zslice can run (the G-code of the source
//!   has scripts) gets the start and end G-code of zslice.
//! - A retraction of 2.5 mm or more means a bowden extruder.
//!
//! The search (`search`) matches each word of the query to the start of a
//! word of the brand, the series, or the model. A match at the start of the
//! model name, and an exact match of the whole name, rank first.
//!
//! References (see REFERENCES.md): the Cura definition format, the
//! PrusaSlicer vendor bundles, and the OrcaSlicer profiles.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The library file, in native builds. The wasm module leaves it out: the
/// web app loads it as a separate file.
pub const builtin_data: []const u8 = if (builtin.cpu.arch.isWasm()) "" else @embedFile("printers/library.txt");

pub const Flavor = enum { marlin, klipper };

pub const Source = struct {
    key: u8,
    name: []const u8,
    license: []const u8,
    url: []const u8,
    version: []const u8,
};

/// A bed model: its files and its placement (see bed.zig).
pub const Bed = struct {
    mesh: [:0]const u8,
    texture: [:0]const u8,
    offset: [3]f64,
    rect: ?[4]f64,
    source: u8,
};

pub const Brand = struct {
    name: []const u8,
    /// The models of the brand: `first` to `end` (not included).
    first: u32,
    end: u32,
};

pub const Model = struct {
    brand: u32,
    id: []const u8,
    name: []const u8,
    /// The name for the user: the brand and the name, or the name alone
    /// if it starts with the brand ("Voron 2.4 350").
    title: [:0]const u8 = "",
    series: []const u8,
    /// One letter for each source: c Cura, p PrusaSlicer, o OrcaSlicer.
    sources: []const u8,
    bed_x: f64,
    bed_y: f64,
    height: f64,
    origin_x: f64,
    origin_y: f64,
    round: bool,
    nozzle: f64,
    /// The nozzle sizes of the model, as "0.25;0.4;0.6", or "".
    nozzles: []const u8,
    filament: f64,
    heated_bed: bool,
    heated_chamber: bool,
    /// The values below are 0 when the source does not tell them.
    max_speed: f64,
    max_accel: f64,
    max_z_speed: f64,
    corner: f64,
    flavor: Flavor,
    /// The firmware, for the user: "Marlin", "Klipper", "RepRapFirmware".
    firmware: []const u8,
    /// "corexy", "i3", "delta", or "".
    kinematics: []const u8,
    retract: f64,
    retract_speed: f64,
    start: ?u32,
    end: ?u32,
    extruders: u32,
    /// The number of the bed model in `Library.beds`, or null.
    bed: ?u32 = null,
};

pub const Error = error{ InvalidLibrary, OutOfMemory };

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    sources: []Source,
    gcodes: [][]const u8,
    brands: []Brand,
    models: []Model,
    beds: []Bed = &.{},

    /// Parses the bytes of a library file. The library copies what it
    /// keeps, so `data` can go after the call.
    pub fn parse(gpa: Allocator, data: []const u8) Error!*Library {
        const lib = try gpa.create(Library);
        lib.* = .{ .arena = .init(gpa), .sources = &.{}, .gcodes = &.{}, .brands = &.{}, .models = &.{} };
        errdefer lib.deinit();
        try lib.load(data);
        return lib;
    }

    pub fn deinit(self: *Library) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn load(self: *Library, data: []const u8) Error!void {
        const a = self.arena.allocator();
        // Each field ends with a 0 byte (a tab or a line end before), so
        // the C API can give the fields as C strings.
        const text = try a.allocSentinel(u8, data.len, 0);
        @memcpy(text, data);
        var sources: std.ArrayList(Source) = .empty;
        var gcodes: std.ArrayList([]const u8) = .empty;
        var brands: std.ArrayList(Brand) = .empty;
        var models: std.ArrayList(Model) = .empty;
        var beds: std.ArrayList(Bed) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        const head = lines.next() orelse return error.InvalidLibrary;
        if (!std.mem.startsWith(u8, std.mem.trimEnd(u8, head, "\r"), "zslice-printers 1")) return error.InvalidLibrary;
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len < 2 or line[0] == '#') continue;
            if (line[1] != '\t') return error.InvalidLibrary;
            const rest = line[2..];
            switch (line[0]) {
                'S' => {
                    var f: Fields = .init(rest);
                    const key = f.next();
                    try sources.append(a, .{ .key = if (key.len > 0) key[0] else '?', .name = f.next(), .license = f.next(), .url = f.next(), .version = f.next() });
                },
                'G' => try gcodes.append(a, try unescape(a, rest)),
                'D' => try beds.append(a, try parseBed(a, rest)),
                'B' => {
                    if (brands.items.len > 0) brands.items[brands.items.len - 1].end = @intCast(models.items.len);
                    try brands.append(a, .{ .name = rest, .first = @intCast(models.items.len), .end = @intCast(models.items.len) });
                },
                'P' => {
                    if (brands.items.len == 0) return error.InvalidLibrary;
                    var m = try parseModel(rest, @intCast(brands.items.len - 1), gcodes.items.len, beds.items.len);
                    const brand = brands.items[brands.items.len - 1].name;
                    m.title = if (std.ascii.startsWithIgnoreCase(m.name, brand))
                        try a.dupeZ(u8, m.name)
                    else
                        try std.fmt.allocPrintSentinel(a, "{s} {s}", .{ brand, m.name }, 0);
                    try models.append(a, m);
                },
                else => {}, // a record of a later version
            }
            const off = @intFromPtr(raw.ptr) - @intFromPtr(text.ptr);
            for (text[off .. off + raw.len]) |*c| if (c.* == '\t' or c.* == '\r') {
                c.* = 0;
            };
            if (off + raw.len < text.len) text[off + raw.len] = 0;
        }
        if (brands.items.len > 0) brands.items[brands.items.len - 1].end = @intCast(models.items.len);
        self.sources = sources.items;
        self.gcodes = gcodes.items;
        self.brands = brands.items;
        self.models = models.items;
        self.beds = beds.items;
    }

    /// The bed model of model `i`, or null.
    pub fn bed(self: *const Library, i: usize) ?Bed {
        if (i >= self.models.len) return null;
        const k = self.models[i].bed orelse return null;
        return if (k < self.beds.len) self.beds[k] else null;
    }

    /// The model of a machine profile: by `machine.model` (the id that
    /// `profileText` writes), else by a name that is the title of a model
    /// (a profile from before the id). Null if none fits.
    pub fn findMachine(self: *const Library, id: []const u8, name: []const u8) ?usize {
        if (id.len > 0) if (self.find(id)) |i| return i;
        if (name.len == 0) return null;
        for (self.models, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.title, name)) return i;
        return null;
    }

    /// The index of the model with this id, or null.
    pub fn find(self: *const Library, id: []const u8) ?usize {
        for (self.models, 0..) |m, i| if (std.mem.eql(u8, m.id, id)) return i;
        return null;
    }

    /// The sources of a model as names, for example "Cura, OrcaSlicer".
    pub fn sourceNames(self: *const Library, m: Model, w: *Writer) Writer.Error!void {
        var first = true;
        for (m.sources) |k| for (self.sources) |s| if (s.key == k) {
            if (!first) try w.writeAll(", ");
            try w.writeAll(s.name);
            first = false;
        };
    }

    /// The models that match `query`, best first, into `out`. `brand`
    /// limits the search to one brand. An empty query gives all models (of
    /// the brand) in the order of the library. Returns the count of
    /// matches, which can be more than `out.len`.
    pub fn search(self: *const Library, query: []const u8, brand: ?usize, out: []u32) usize {
        var words: [8][]const u8 = undefined;
        var n_words: usize = 0;
        var it = std.mem.tokenizeAny(u8, query, " \t,/");
        while (it.next()) |w| {
            if (n_words == words.len) break;
            words[n_words] = w;
            n_words += 1;
        }
        const lo: usize = if (brand) |b| (if (b < self.brands.len) self.brands[b].first else 0) else 0;
        const hi: usize = if (brand) |b| (if (b < self.brands.len) self.brands[b].end else 0) else self.models.len;
        var count: usize = 0;
        // Insertion into `out` by score, so the best `out.len` stay.
        var scores: [512]u32 = undefined;
        const keep = @min(out.len, scores.len);
        var i = lo;
        while (i < hi) : (i += 1) {
            const m = self.models[i];
            const s = score(self.brands[m.brand].name, m, words[0..n_words]) orelse continue;
            count += 1;
            // Find the place: after each entry with a higher or equal score.
            var pos: usize = @min(count - 1, keep);
            while (pos > 0 and scores[pos - 1] < s) : (pos -= 1) {}
            if (pos >= keep) continue;
            var k: usize = @min(count - 1, keep - 1);
            while (k > pos) : (k -= 1) {
                out[k] = out[k - 1];
                scores[k] = scores[k - 1];
            }
            out[pos] = @intCast(i);
            scores[pos] = s;
        }
        return count;
    }

    /// The model that fits what a printer on the network tells best: a
    /// model name (for example from the TXT record of its service, or its
    /// host name) and the size of its bed (0 when not known). Returns null
    /// when nothing fits well.
    pub fn match(self: *const Library, hint: []const u8, bed_x: f64, bed_y: f64, height: f64) ?usize {
        var best: ?usize = null;
        var best_score: i64 = 0;
        var hint_key: [128]u8 = undefined;
        const hk = normKey(hint, &hint_key);
        for (self.models, 0..) |m, i| {
            var s: i64 = 0;
            if (hk.len >= 2) {
                var buf: [192]u8 = undefined;
                var full_buf: [256]u8 = undefined;
                const name_key = normKey(m.name, &buf);
                const full = std.fmt.bufPrint(&full_buf, "{s} {s}", .{ self.brands[m.brand].name, m.name }) catch m.name;
                var full_key_buf: [256]u8 = undefined;
                const full_key = normKey(full, &full_key_buf);
                if (std.mem.eql(u8, hk, name_key) or std.mem.eql(u8, hk, full_key)) {
                    s += 1000;
                } else if (name_key.len >= 3 and std.mem.indexOf(u8, hk, name_key) != null) {
                    s += 200 + @as(i64, @intCast(name_key.len)) * 10;
                }
            }
            if (bed_x > 0 and bed_y > 0) {
                const dx = @abs(m.bed_x - bed_x);
                const dy = @abs(m.bed_y - bed_y);
                if (dx <= 1 and dy <= 1) s += 100 else if (s > 0 and (dx > 15 or dy > 15)) s -= 300;
                if (height > 0 and @abs(m.height - height) <= 1) s += 20;
            }
            if (s > best_score) {
                best_score = s;
                best = i;
            }
        }
        // A bed size alone fits many models: it needs a name too.
        return if (best_score >= 200) best else null;
    }

    /// The G-code text number `i`, or null.
    pub fn gcode(self: *const Library, i: ?u32) ?[]const u8 {
        const k = i orelse return null;
        return if (k < self.gcodes.len) self.gcodes[k] else null;
    }

    /// Writes the machine profile of model `i` (a profile of the machine
    /// group, see profile.zig) with a nozzle of `nozzle` mm (0: the nozzle
    /// of the model).
    pub fn profileText(self: *const Library, i: usize, nozzle: f64, w: *Writer) Writer.Error!void {
        const m = self.models[i];
        try w.print("# {s}, from the zslice printer library (", .{m.title});
        try self.sourceNames(m, w);
        try w.writeAll(").\n");
        try w.writeAll("name = \"");
        try writeEscaped(w, m.title);
        try w.writeAll("\"\n");
        try w.writeAll("model = \"");
        try writeEscaped(w, m.id);
        try w.writeAll("\"\n");
        try w.print("bed_size_x = {d}\nbed_size_y = {d}\nmax_height = {d}\n", .{ m.bed_x, m.bed_y, m.height });
        if (m.origin_x != 0) try w.print("origin_x = {d}\n", .{m.origin_x});
        if (m.origin_y != 0) try w.print("origin_y = {d}\n", .{m.origin_y});
        try w.print("nozzle_diameter = {d}\n", .{if (nozzle > 0) nozzle else m.nozzle});
        const speeds = printSpeed(m);
        try w.print("max_speed = {d}\ntravel_speed = {d}\n", .{ speeds.print, speeds.travel });
        if (m.max_z_speed > 0) try w.print("max_z_speed = {d}\n", .{std.math.clamp(m.max_z_speed, 2, 30)});
        if (m.max_accel > 0) try w.print("max_accel = {d}\n", .{std.math.clamp(m.max_accel, 100, 30000)});
        if (m.corner > 0) try w.print("corner_speed = {d}\n", .{std.math.clamp(m.corner, 1, 30)});
        if (m.flavor == .klipper) try w.writeAll("gcode_flavor = \"klipper\"\n");
        const bowden = m.retract >= 2.5;
        try w.print("extruder = \"{s}\"\n", .{if (bowden) "bowden" else "direct"});
        if (m.retract > 0) try w.print("retract_length = {d}\n", .{std.math.clamp(m.retract, 0, 15)});
        if (m.retract_speed > 0) try w.print("retract_speed = {d}\n", .{std.math.clamp(m.retract_speed, 5, 150)});
        if (self.gcode(m.start)) |g| {
            try w.writeAll("start_gcode = ");
            try writeMultiline(w, g);
            try w.writeByte('\n');
        }
        if (self.gcode(m.end)) |g| {
            try w.writeAll("end_gcode = ");
            try writeMultiline(w, g);
            try w.writeByte('\n');
        }
    }
};

/// The print and travel speeds of zslice for a model, in mm/s. A project
/// gives each feature a ratio of the print speed. The speed follows the
/// acceleration of the printer, and stays under the limit of its firmware.
pub fn printSpeed(m: Model) struct { print: f64, travel: f64 } {
    const a = m.max_accel;
    const print: f64, const travel: f64 = if (a <= 0) .{ 150, 150 } else if (a < 1000) .{ 100, 120 } else if (a < 3000) .{ 150, 150 } else if (a < 10000) .{ 200, 250 } else .{ 300, 400 };
    const limit = if (m.max_speed > 0) m.max_speed else 1e9;
    return .{ .print = @min(print, limit), .travel = @min(travel, limit) };
}

/// The rank of a model for a query, or null if a word does not match.
fn score(brand: []const u8, m: Model, words: []const []const u8) ?u32 {
    if (words.len == 0) return 1;
    var total: u32 = 1;
    for (words) |w| {
        const in_name = wordMatch(m.name, w);
        const in_brand = wordMatch(brand, w);
        const in_series = wordMatch(m.series, w);
        if (in_name == .none and in_brand == .none and in_series == .none) return null;
        total += switch (in_name) {
            .first => 40,
            .word => 20,
            .inside => 8,
            .none => 0,
        };
        if (in_brand != .none) total += 10;
        if (in_series != .none) total += 5;
    }
    // The whole query is the name: first.
    var a: [192]u8 = undefined;
    var b: [192]u8 = undefined;
    if (words.len > 0 and std.mem.eql(u8, normKey(m.name, &a), normKey(words[words.len - 1], &b))) total += 100;
    // Shorter names first among equal matches ("K1" before "K1 Max").
    total = total * 64 + 63 - @as(u32, @intCast(@min(m.name.len, 63)));
    return total;
}

const Match = enum { none, inside, word, first };

/// Where `word` matches in `text`, with no regard to case: at the start of
/// the text, at the start of another word, or inside a word. Dashes and
/// dots in the text do not count ("ender3" matches "Ender-3").
fn wordMatch(text: []const u8, word: []const u8) Match {
    var kw: [64]u8 = undefined;
    const k = normKey(word, &kw);
    if (k.len == 0) return .first;
    var kt: [192]u8 = undefined;
    var starts: [192]bool = undefined;
    var n: usize = 0;
    var new_word = true;
    for (text) |c| {
        if (n == kt.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            const digit_after_letter = n > 0 and std.ascii.isDigit(c) != std.ascii.isDigit(kt[n - 1]);
            kt[n] = std.ascii.toLower(c);
            starts[n] = new_word or digit_after_letter;
            n += 1;
            new_word = false;
        } else if (c == ' ' or c == '(' or c == '/' or c == '&' or c == '+') {
            new_word = true;
        }
    }
    const t = kt[0..n];
    var best: Match = .none;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, t, from, k)) |pos| {
        const m: Match = if (pos == 0) .first else if (starts[pos]) .word else .inside;
        if (@intFromEnum(m) > @intFromEnum(best)) best = m;
        from = pos + 1;
    }
    return best;
}

/// The letters and digits of `text` in lower case.
fn normKey(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (n == buf.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            buf[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return buf[0..n];
}

const Fields = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    fn init(text: []const u8) Fields {
        return .{ .it = std.mem.splitScalar(u8, text, '\t') };
    }
    fn next(self: *Fields) []const u8 {
        return self.it.next() orelse "";
    }
    fn num(self: *Fields) f64 {
        const t = self.next();
        if (t.len == 0) return 0;
        return std.fmt.parseFloat(f64, t) catch 0;
    }
    fn index(self: *Fields, n: usize) ?u32 {
        const t = self.next();
        if (t.len == 0) return null;
        const v = std.fmt.parseInt(u32, t, 10) catch return null;
        return if (v < n) v else null;
    }
};

/// A D line: mesh, texture, offset, rect, source. The file names get a 0
/// byte at their end (the C API gives them as C strings).
fn parseBed(a: Allocator, text: []const u8) Error!Bed {
    var f: Fields = .init(text);
    const mesh = try a.dupeZ(u8, f.next());
    const texture = try a.dupeZ(u8, f.next());
    var offset: [3]f64 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, f.next(), ';');
    for (&offset) |*o| o.* = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
    const rect_text = f.next();
    var rect: ?[4]f64 = null;
    if (rect_text.len > 0) {
        var r: [4]f64 = undefined;
        var ri = std.mem.splitScalar(u8, rect_text, ';');
        for (&r) |*x| x.* = std.fmt.parseFloat(f64, ri.next() orelse "") catch return error.InvalidLibrary;
        rect = r;
    }
    const src = f.next();
    // A file name is a plain name in the bed folder: no path.
    for ([_][]const u8{ mesh, texture }) |name| {
        if (std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.startsWith(u8, name, ".")) return error.InvalidLibrary;
    }
    return .{ .mesh = mesh, .texture = texture, .offset = offset, .rect = rect, .source = if (src.len > 0) src[0] else '?' };
}

fn parseModel(text: []const u8, brand: u32, n_gcodes: usize, n_beds: usize) Error!Model {
    var f: Fields = .init(text);
    var m: Model = undefined;
    m.brand = brand;
    m.id = f.next();
    m.name = f.next();
    m.series = f.next();
    m.sources = f.next();
    m.bed_x = f.num();
    m.bed_y = f.num();
    m.height = f.num();
    m.origin_x = f.num();
    m.origin_y = f.num();
    m.round = std.mem.eql(u8, f.next(), "r");
    m.nozzle = f.num();
    m.nozzles = f.next();
    m.filament = f.num();
    const heat = f.next();
    m.heated_bed = std.mem.indexOfScalar(u8, heat, 'b') != null;
    m.heated_chamber = std.mem.indexOfScalar(u8, heat, 'c') != null;
    m.max_speed = f.num();
    m.max_accel = f.num();
    m.max_z_speed = f.num();
    m.corner = f.num();
    m.flavor = if (std.mem.eql(u8, f.next(), "klipper")) .klipper else .marlin;
    m.firmware = f.next();
    m.kinematics = f.next();
    m.retract = f.num();
    m.retract_speed = f.num();
    m.start = f.index(n_gcodes);
    m.end = f.index(n_gcodes);
    const e = f.num();
    m.extruders = if (e >= 1 and e < 64) @intFromFloat(e) else 1;
    m.bed = f.index(n_beds);
    if (m.id.len == 0 or m.name.len == 0 or !(m.bed_x > 0) or !(m.bed_y > 0) or !(m.height > 0)) return error.InvalidLibrary;
    if (!(m.nozzle > 0)) m.nozzle = 0.4;
    if (!(m.filament > 0)) m.filament = 1.75;
    return m;
}

fn unescape(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
    const out = try a.allocSentinel(u8, text.len, 0);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            out[n] = switch (text[i]) {
                'n' => '\n',
                't' => '\t',
                else => text[i],
            };
        } else out[n] = text[i];
        n += 1;
    }
    out[n] = 0;
    return out[0..n];
}

/// A field of the library as a C string: each field ends with a 0 byte.
pub fn cstr(text: []const u8) [*:0]const u8 {
    std.debug.assert(text.ptr[text.len] == 0);
    return @ptrCast(text.ptr);
}

fn writeEscaped(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n', '\t' => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
}

/// A TOML multi-line string: a literal string, or a basic string with
/// escapes if the text has three single quotes.
fn writeMultiline(w: *Writer, text: []const u8) Writer.Error!void {
    if (std.mem.indexOf(u8, text, "'''") == null and !std.mem.endsWith(u8, text, "'")) {
        try w.print("'''\n{s}'''", .{text});
        return;
    }
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ---- tests ----

const testing = std.testing;

/// The test library, with "|" for each tab.
const test_lib = tabs(
    \\zslice-printers 1
    \\# test
    \\S|c|Cura|LGPL-3.0-or-later|https://github.com/Ultimaker/Cura|5.11
    \\S|o|OrcaSlicer|AGPL-3.0|https://github.com/SoftFever/OrcaSlicer|2.3
    \\G|G28\nM109 S{first_layer_nozzle_temp}
    \\G|M104 S0\nPRINT_END
    \\D|ender3-bed.mesh|ender3.png|0;0;-0.45|-110;-110;110;110|o
    \\B|Creality
    \\P|creality-ender-3|Ender-3|Ender|oc|220|220|250|0|0||0.4|0.2;0.4;0.6|1.75|b|500|500|10|8|marlin|Marlin|i3|5|60|0|1|1|0
    \\P|creality-k1-max|K1 Max|K1|o|300|300|300|0|0||0.4||1.75|bc|800|20000|20|20|klipper|Klipper|corexy|0.8|40||1|1
    \\B|FLSun
    \\P|flsun-q5|Q5|Q|c|200|200|200|-100|-100|r|0.4||1.75|b|||||marlin|Marlin|delta|||||1
);

fn tabs(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10000);
        var out: [text.len]u8 = undefined;
        for (text, 0..) |ch, i| out[i] = if (ch == '|') '\t' else ch;
        const final = out;
        return &final;
    }
}

test "parse a library" {
    const lib = try Library.parse(testing.allocator, test_lib);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 2), lib.sources.len);
    try testing.expectEqual(@as(usize, 2), lib.gcodes.len);
    try testing.expectEqualStrings("G28\nM109 S{first_layer_nozzle_temp}", lib.gcodes[0]);
    try testing.expectEqual(@as(usize, 2), lib.brands.len);
    try testing.expectEqual(@as(u32, 2), lib.brands[0].end);
    try testing.expectEqual(@as(usize, 3), lib.models.len);
    const k1 = lib.models[1];
    try testing.expectEqualStrings("K1 Max", k1.name);
    try testing.expect(k1.heated_chamber);
    try testing.expectEqual(Flavor.klipper, k1.flavor);
    try testing.expectEqual(@as(?u32, null), k1.start);
    const q5 = lib.models[2];
    try testing.expect(q5.round);
    try testing.expectEqual(@as(f64, -100), q5.origin_x);
    try testing.expectEqual(@as(f64, 0), q5.max_accel);
    try testing.expectEqual(@as(?usize, 1), lib.find("creality-k1-max"));
    // Each field is a C string.
    try testing.expectEqualStrings("Klipper", std.mem.span(cstr(k1.firmware)));
    try testing.expectEqualStrings("FLSun", std.mem.span(cstr(lib.brands[1].name)));
    try testing.expectEqualStrings("M104 S0\nPRINT_END", std.mem.span(cstr(lib.gcodes[1])));
    // The bed model of the Ender-3, and none for the K1 Max.
    const bed = lib.bed(0).?;
    try testing.expectEqualStrings("ender3-bed.mesh", bed.mesh);
    try testing.expectEqualStrings("ender3.png", bed.texture);
    try testing.expectEqual(@as(f64, -0.45), bed.offset[2]);
    try testing.expectEqual(@as(f64, 110), bed.rect.?[2]);
    try testing.expect(lib.bed(1) == null);
    // The model of a machine profile: by id, else by its title.
    try testing.expectEqual(@as(?usize, 1), lib.findMachine("creality-k1-max", ""));
    try testing.expectEqual(@as(?usize, 2), lib.findMachine("", "FLSun Q5"));
    try testing.expectEqual(@as(?usize, null), lib.findMachine("", "My printer"));
}

test "a bed file name has no path" {
    const bad = comptime tabs(
        \\zslice-printers 1
        \\D|../x.mesh||0;0;0||o
    );
    try testing.expectError(error.InvalidLibrary, Library.parse(testing.allocator, bad));
}

test "a bad library is an error" {
    try testing.expectError(error.InvalidLibrary, Library.parse(testing.allocator, "hello\n"));
    try testing.expectError(error.InvalidLibrary, Library.parse(testing.allocator, "zslice-printers 1\nP\tx\n"));
}

test "search ranks the name first" {
    const lib = try Library.parse(testing.allocator, test_lib);
    defer lib.deinit();
    var out: [8]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), lib.search("", null, &out));
    try testing.expectEqual(@as(usize, 1), lib.search("ender3", null, &out));
    try testing.expectEqual(@as(u32, 0), out[0]);
    try testing.expectEqual(@as(usize, 1), lib.search("k1", null, &out));
    try testing.expectEqual(@as(usize, 2), lib.search("creality", null, &out));
    try testing.expectEqual(@as(usize, 1), lib.search("creality max", null, &out));
    try testing.expectEqual(@as(u32, 1), out[0]);
    try testing.expectEqual(@as(usize, 0), lib.search("prusa", null, &out));
    try testing.expectEqual(@as(usize, 1), lib.search("", 1, &out));
    try testing.expectEqual(@as(u32, 2), out[0]);
    // A short output keeps the best matches.
    var one: [1]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), lib.search("", null, &one));
}

test "match a printer from the network" {
    const lib = try Library.parse(testing.allocator, test_lib);
    defer lib.deinit();
    try testing.expectEqual(@as(?usize, 1), lib.match("Creality K1 Max", 0, 0, 0));
    try testing.expectEqual(@as(?usize, 1), lib.match("k1max", 300, 300, 300));
    try testing.expectEqual(@as(?usize, 0), lib.match("my ender-3 printer", 220, 220, 0));
    // A bed size alone is not enough.
    try testing.expectEqual(@as(?usize, null), lib.match("", 220, 220, 250));
    try testing.expectEqual(@as(?usize, null), lib.match("octopi", 0, 0, 0));
}

test "a profile of a model loads as a machine profile" {
    const profile = @import("profile.zig");
    const Settings = @import("settings.zig").Settings;
    const lib = try Library.parse(testing.allocator, test_lib);
    defer lib.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var aw: Writer.Allocating = .init(arena.allocator());
    try lib.profileText(1, 0.6, &aw.writer);
    var s: Settings = .{};
    var diag: profile.Diagnostic = .{};
    try profile.apply(arena.allocator(), &s, .machine, "k1", aw.written(), null, &diag);
    try testing.expectEqualStrings("Creality K1 Max", s.machine.name);
    try testing.expectEqual(@as(f64, 300), s.machine.bed_size_x);
    try testing.expectEqual(@as(f64, 0.6), s.machine.nozzle_diameter);
    try testing.expectEqual(@as(f64, 300), s.machine.max_speed);
    try testing.expectEqual(@import("settings.zig").GcodeFlavor.klipper, s.machine.gcode_flavor);
    try testing.expectEqualStrings("M104 S0\nPRINT_END", s.machine.end_gcode);

    aw.clearRetainingCapacity();
    try lib.profileText(2, 0, &aw.writer);
    s = .{};
    try profile.apply(arena.allocator(), &s, .machine, "q5", aw.written(), null, &diag);
    try testing.expectEqual(@as(f64, -100), s.machine.origin_y);
    try testing.expectEqual(@as(f64, 150), s.machine.max_speed);

    aw.clearRetainingCapacity();
    try lib.profileText(0, 0, &aw.writer);
    s = .{};
    try profile.apply(arena.allocator(), &s, .machine, "e3", aw.written(), null, &diag);
    try testing.expectEqual(@as(f64, 100), s.machine.max_speed);
    try testing.expectEqual(@import("settings.zig").ExtruderKind.bowden, s.machine.extruder);
    try testing.expectEqualStrings("G28\nM109 S{first_layer_nozzle_temp}", s.machine.start_gcode);
}

test "each model of the built-in library loads as a machine profile" {
    if (builtin_data.len == 0) return error.SkipZigTest;
    const profile = @import("profile.zig");
    const Settings = @import("settings.zig").Settings;
    const lib = try Library.parse(testing.allocator, builtin_data);
    defer lib.deinit();
    try testing.expect(lib.models.len > 500);
    try testing.expect(lib.brands.len > 100);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (lib.models, 0..) |m, i| {
        _ = arena.reset(.retain_capacity);
        var aw: Writer.Allocating = .init(arena.allocator());
        try lib.profileText(i, 0, &aw.writer);
        var s: Settings = .{};
        var diag: profile.Diagnostic = .{};
        profile.apply(arena.allocator(), &s, .machine, m.id, aw.written(), null, &diag) catch |e| {
            std.debug.print("{s}: line {d}: {s}\n", .{ m.id, diag.line, diag.message });
            return e;
        };
        try testing.expectEqual(m.bed_x, s.machine.bed_size_x);
    }
    // Common printers are in the library.
    var out: [4]u32 = undefined;
    try testing.expect(lib.search("lulzbot taz", null, &out) > 0);
    try testing.expect(lib.search("prusa mk4", null, &out) > 0);
    try testing.expect(lib.search("ender 3 v2", null, &out) > 0);
}
