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
//! In a P line: `sources` has one letter for each source (l Cura LulzBot Edition, c Cura,
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
//! - A model with no G-code in its sources gets the start and end G-code
//!   of zslice. The G-code of a source keeps its variables and its
//!   scripts: gcode_vars.zig fills them in when zslice writes the G-code.
//! - A retraction of 2.5 mm or more means a bowden extruder.
//! - A model of a family in `cooling_families` gets the air around the
//!   print and the air speed of its fans, for the simulated print.
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

/// The G-code flavor of a model: the dialect of its acceleration
/// commands (see `Machine.gcode_flavor` in settings.zig).
pub const Flavor = enum { marlin, klipper, reprap, repetier };

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
    /// One letter for each source: c Cura, p PrusaSlicer, o OrcaSlicer, l Cura
    /// LulzBot Edition.
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
        return self.findByWords(name);
    }

    /// The model whose title words are all in `name`, with the most words
    /// (the longest match), or null. A name from another slicer has more
    /// words, or other marks: "LulzBot TAZ Workhorse | SE | 0.5 mm" is the
    /// model "TAZ Workhorse SE 0.5 mm".
    fn findByWords(self: *const Library, name: []const u8) ?usize {
        const seps = " \t|,/()_-";
        var best: ?usize = null;
        var best_n: usize = 0;
        for (self.models, 0..) |m, i| {
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, m.title, seps);
            const all = while (it.next()) |w| {
                var nt = std.mem.tokenizeAny(u8, name, seps);
                const found = while (nt.next()) |x| {
                    if (std.ascii.eqlIgnoreCase(w, x)) break true;
                } else false;
                if (!found) break false;
                n += 1;
            } else true;
            // Two words at least, so a short title ("Ender 3") does not
            // match a longer name by chance.
            if (all and n >= 2 and n > best_n) {
                best = i;
                best_n = n;
            }
        }
        return best;
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
        return self.matchNozzle(hint, bed_x, bed_y, height, 0);
    }

    /// As `match`, with the nozzle of the printer (0: not known). A name
    /// that starts the names of several models (a family, such as "LulzBot
    /// TAZ Workhorse" with ten tool heads) matches the family. In it, the
    /// model with that nozzle wins; with no nozzle, the stock size (the
    /// nozzle nearest 0.45 mm), so a 0.5 mm printer does not get a 1.2 mm
    /// line width.
    pub fn matchNozzle(self: *const Library, hint: []const u8, bed_x: f64, bed_y: f64, height: f64, nozzle: f64) ?usize {
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
                } else if (hk.len >= 6 and (std.mem.startsWith(u8, full_key, hk) or std.mem.startsWith(u8, name_key, hk))) {
                    // The name of a family.
                    s += 300;
                }
                if (s > 0) {
                    if (nozzle > 0) {
                        if (@abs(m.nozzle - nozzle) < 0.01) s += 150;
                    } else {
                        s -= @intFromFloat(@round(@abs(m.nozzle - 0.45) * 40));
                    }
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
        if (m.flavor != .marlin) try w.print("gcode_flavor = \"{s}\"\n", .{@tagName(m.flavor)});
        const bowden = m.retract >= 2.5;
        try w.print("extruder = \"{s}\"\n", .{if (bowden) "bowden" else "direct"});
        if (m.retract > 0) try w.print("retract_length = {d}\n", .{std.math.clamp(m.retract, 0, 15)});
        if (m.retract_speed > 0) try w.print("retract_speed = {d}\n", .{std.math.clamp(m.retract_speed, 5, 150)});
        if (coolingOf(m.id)) |c| {
            try w.print("# Cooling: {s}. The air speed is an estimate from the size of the fans.\n", .{c.what});
            try w.print("chamber_temp = {d}\npart_fan_air = {d}\n", .{ c.chamber_temp, c.part_fan_air });
        }
        // The start and the end G-code of Bambu Studio for a model that has
        // newer ones than the presets of the library (see bambuTemplate).
        if (bambuTemplate(m.id, .start) orelse self.gcode(m.start)) |g| {
            try w.writeAll("start_gcode = ");
            try writeMultiline(w, g);
            try w.writeByte('\n');
        }
        if (bambuTemplate(m.id, .end) orelse self.gcode(m.end)) |g| {
            try w.writeAll("end_gcode = ");
            try writeMultiline(w, g);
            try w.writeByte('\n');
        }
        // A printer with a unit that feeds many filaments: a tool change,
        // with the change G-code of the maker.
        // A head with two nozzles: the reach of each (the Bambu Lab
        // printer presets, extruder_printable_area and
        // extruder_printable_height). Only the limits inside the bed.
        if (bambu(m.id)) |b| if (b.nozzles >= 2) {
            try w.writeAll("nozzles = 2\n");
            if (b.max_x[0] > 0 and b.max_x[0] < m.bed_x) try w.print("nozzle1_max_x = {d}\n", .{b.max_x[0]});
            if (b.height[0] > 0 and b.height[0] < m.height) try w.print("nozzle1_max_height = {d}\n", .{b.height[0]});
            if (b.min_x[1] > 0) try w.print("nozzle2_min_x = {d}\n", .{b.min_x[1]});
            if (b.height[1] > 0 and b.height[1] < m.height) try w.print("nozzle2_max_height = {d}\n", .{b.height[1]});
        };
        if (changeGcode(m.id)) |g| {
            try w.writeAll("filament_change = \"tool\"\nchange_gcode = ");
            try writeMultiline(w, g);
            try w.writeByte('\n');
        }
    }
};

/// The facts of a Bambu Lab printer that its file and its nozzles need
/// (src/printers/bambu.txt, made by tools/bambu_facts.py from the machine
/// presets of OrcaSlicer).
pub const Bambu = struct {
    /// The model code of Bambu Studio ("N6"), and its model name
    /// ("Bambu Lab X2D").
    code: []const u8,
    name: []const u8,
    nozzles: u32,
    /// The reach of each nozzle on a printer with two: the least x, the
    /// most x, and the height (mm); 0 for none (the bed).
    min_x: [2]f64 = .{ 0, 0 },
    max_x: [2]f64 = .{ 0, 0 },
    height: [2]f64 = .{ 0, 0 },
    /// The extruder types and the default nozzle volume types (";"
    /// between nozzles: "Direct Drive;Bowden"), and the extruder variant
    /// lists ("|" between nozzles), as Bambu Studio names them.
    types: []const u8 = "Direct Drive",
    volumes: []const u8 = "Standard",
    variants: []const u8 = "",
};

const bambu_text = @embedFile("printers/bambu.txt");

/// The facts of the Bambu Lab printer with the model id `id` of the
/// printer library ("bambu-lab-x2d"), or null.
pub fn bambu(id: []const u8) ?Bambu {
    var lines = std.mem.splitScalar(u8, bambu_text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "B\t")) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        _ = f.next();
        if (!std.mem.eql(u8, f.next() orelse continue, id)) continue;
        var b: Bambu = .{ .code = f.next() orelse return null, .name = f.next() orelse return null, .nozzles = std.fmt.parseInt(u32, f.next() orelse "1", 10) catch 1 };
        for (0..b.nozzles) |k| {
            if (k >= 2) break;
            const v = [3]f64{
                std.fmt.parseFloat(f64, f.next() orelse "") catch 0,
                std.fmt.parseFloat(f64, f.next() orelse "") catch 0,
                std.fmt.parseFloat(f64, f.next() orelse "") catch 0,
            };
            b.min_x[k] = v[0];
            b.max_x[k] = v[1];
            b.height[k] = v[2];
        }
        b.types = f.next() orelse b.types;
        b.volumes = f.next() orelse b.volumes;
        b.variants = f.next() orelse "";
        return b;
    }
    return null;
}

test "printers: the facts of the Bambu Lab X2D and of a printer with one nozzle" {
    const x2d = bambu("bambu-lab-x2d").?;
    try std.testing.expectEqualStrings("N6", x2d.code);
    try std.testing.expectEqualStrings("Bambu Lab X2D", x2d.name);
    try std.testing.expectEqual(@as(u32, 2), x2d.nozzles);
    try std.testing.expectEqual(@as(f64, 20.5), x2d.min_x[1]);
    try std.testing.expectEqual(@as(f64, 256), x2d.height[1]);
    try std.testing.expectEqualStrings("Direct Drive;Bowden", x2d.types);
    try std.testing.expect(std.mem.startsWith(u8, x2d.variants, "Direct Drive Standard,"));
    const h2d = bambu("bambu-lab-h2d").?;
    try std.testing.expectEqual(@as(f64, 325), h2d.max_x[0]);
    const p1s = bambu("bambu-lab-p1s").?;
    try std.testing.expectEqualStrings("C12", p1s.code);
    try std.testing.expectEqual(@as(u32, 1), p1s.nozzles);
    try std.testing.expect(bambu("creality-ender-3") == null);
}

/// The filament change G-code of a model (see Machine.change_gcode), or
/// null. The text of the Bambu Lab X2D comes from its machine preset in
/// the BBL profiles of OrcaSlicer (see REFERENCES.md); gcode_vars.zig
/// fills in its variables.
/// The start or the end G-code of a Bambu Lab printer from Bambu Studio,
/// when it is newer than the one of the presets of OrcaSlicer, or null.
/// The X2D: Bambu Studio 02.09.01.70 (start 2026/10/20, end 2026/07/29),
/// from the config block of a .gcode.3mf that it wrote.
pub fn bambuTemplate(id: []const u8, which: enum { start, end }) ?[]const u8 {
    if (std.mem.eql(u8, id, "bambu-lab-x2d")) return switch (which) {
        .start => @embedFile("printers/bambu/bambu-lab-x2d-start.gcode"),
        .end => @embedFile("printers/bambu/bambu-lab-x2d-end.gcode"),
    };
    return null;
}

/// The project_settings.config of a Bambu Studio file of a model (the
/// X2D: Bambu Studio 02.09.01.70), the base of the project settings of
/// its .gcode.3mf, or null.
pub fn bambuProject(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "bambu-lab-x2d")) return @embedFile("printers/bambu/bambu-lab-x2d-project.json");
    return null;
}

/// The config block of the G-code of a Bambu Studio file of a model (the
/// lines between "; CONFIG_BLOCK_START" and "; CONFIG_BLOCK_END"; the X2D:
/// Bambu Studio 02.09.01.70), the base of the config block that zslice
/// writes, or null.
pub fn bambuConfig(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "bambu-lab-x2d")) return @embedFile("printers/bambu/bambu-lab-x2d-config.txt");
    return null;
}

pub fn changeGcode(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "bambu-lab-x2d")) return @embedFile("printers/change/bambu-lab-x2d.gcode");
    return null;
}

/// The cooling of a printer family, for the simulated print: the air
/// around the print with PLA (`machine.chamber_temp`, °C), and the air
/// speed of the part cooling fans at the bead (`machine.part_fan_air`,
/// m/s). The fans and the enclosures come from the makers and their parts
/// stores (see REFERENCES.md). The air speeds are estimates from the size
/// of the fans: a 5015 radial blower through a duct about 6 m/s, a 4010
/// blower about 4 m/s, two 3510 blowers about 5 m/s, and a 5015 with a
/// large side fan (Bambu Lab, Creality K1, QIDI) about 10 m/s. A closed
/// printer with PLA keeps its air at about 35 °C, an estimate: the bed
/// warms it. A heated chamber is off for PLA.
pub const Cooling = struct {
    /// The start of the ids of the models of the family.
    prefix: []const u8,
    chamber_temp: f64,
    part_fan_air: f64,
    /// The fans and the enclosure, in words.
    what: []const u8,
};

pub const cooling_families = [_]Cooling{
    .{ .prefix = "bambu-lab-x1", .chamber_temp = 35, .part_fan_air = 10, .what = "closed; a part fan and a 12 W auxiliary side fan" },
    .{ .prefix = "bambu-lab-p1s", .chamber_temp = 35, .part_fan_air = 10, .what = "closed; a part fan and a 12 W auxiliary side fan" },
    .{ .prefix = "creality-k1", .chamber_temp = 35, .part_fan_air = 10, .what = "closed; a part fan and a 12032 radial side fan" },
    .{ .prefix = "creality-ender-3", .chamber_temp = 25, .part_fan_air = 4, .what = "open frame; one 4010 blower" },
    .{ .prefix = "creality-cr-10", .chamber_temp = 25, .part_fan_air = 4, .what = "open frame; one 4010 blower" },
    .{ .prefix = "prusa-core-one", .chamber_temp = 35, .part_fan_air = 6, .what = "closed, with chamber fans; one 5015 blower" },
    .{ .prefix = "prusa-mk4", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; one 5015 blower" },
    .{ .prefix = "prusa-mk3", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; one 5015 blower" },
    .{ .prefix = "prusa-i3-mk3", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; one 5015 blower" },
    .{ .prefix = "prusa-mini", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; one 5015 blower" },
    .{ .prefix = "prusa-xl", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; one 5015 blower on each tool" },
    .{ .prefix = "voron", .chamber_temp = 35, .part_fan_air = 6, .what = "closed; one 5015 blower (Stealthburner)" },
    .{ .prefix = "qidi-x-max-3", .chamber_temp = 35, .part_fan_air = 10, .what = "closed, with a heated chamber to 65 °C (off for PLA); a part fan and an auxiliary fan" },
    .{ .prefix = "qidi-x-plus-3", .chamber_temp = 35, .part_fan_air = 10, .what = "closed, with a heated chamber (off for PLA); a part fan and an auxiliary fan" },
    .{ .prefix = "ultimaker-s", .chamber_temp = 25, .part_fan_air = 5, .what = "two 3510 radial blowers, one on each side of the head" },
    .{ .prefix = "lulzbot-taz-workhorse", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; a 24 V radial blower on the tool head" },
    .{ .prefix = "lulzbot-taz-pro", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; a 24 V radial blower on the tool head" },
    .{ .prefix = "lulzbot-mini-2", .chamber_temp = 25, .part_fan_air = 6, .what = "open frame; a 24 V radial blower on the tool head" },
};

/// The cooling of the family of a model (the longest prefix of its id),
/// or null if the library has none for it.
pub fn coolingOf(id: []const u8) ?Cooling {
    var best: ?Cooling = null;
    for (cooling_families) |c| {
        if (!std.mem.startsWith(u8, id, c.prefix)) continue;
        if (best == null or c.prefix.len > best.?.prefix.len) best = c;
    }
    return best;
}

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
    const flavor = f.next();
    m.firmware = f.next();
    // The library has "marlin" or "klipper". The firmware tells the other
    // flavors.
    m.flavor = if (std.mem.eql(u8, flavor, "klipper"))
        .klipper
    else if (std.ascii.indexOfIgnoreCase(m.firmware, "reprap") != null)
        .reprap
    else if (std.ascii.indexOfIgnoreCase(m.firmware, "repetier") != null)
        .repetier
    else
        std.meta.stringToEnum(Flavor, flavor) orelse .marlin;
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
    // The cooling of the K1 family: closed, and a large side fan.
    try testing.expectEqual(@as(f64, 35), s.machine.chamber_temp);
    try testing.expectEqual(@as(f64, 10), s.machine.part_fan_air);

    aw.clearRetainingCapacity();
    try lib.profileText(2, 0, &aw.writer);
    s = .{};
    try profile.apply(arena.allocator(), &s, .machine, "q5", aw.written(), null, &diag);
    try testing.expectEqual(@as(f64, -100), s.machine.origin_y);
    // No cooling data for the family: the defaults.
    try testing.expectEqual(@as(f64, 25), s.machine.chamber_temp);
    try testing.expectEqual(@as(f64, 150), s.machine.max_speed);

    aw.clearRetainingCapacity();
    try lib.profileText(0, 0, &aw.writer);
    s = .{};
    try profile.apply(arena.allocator(), &s, .machine, "e3", aw.written(), null, &diag);
    try testing.expectEqual(@as(f64, 100), s.machine.max_speed);
    try testing.expectEqual(@import("settings.zig").ExtruderKind.bowden, s.machine.extruder);
    try testing.expectEqual(@as(f64, 4), s.machine.part_fan_air);
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

test "find a machine by the words of its name" {
    const lib = try Library.parse(testing.allocator, @embedFile("printers/library.txt"));
    defer lib.deinit();
    const i = lib.findMachine("", "LulzBot TAZ Workhorse | SE | 0.5 mm") orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("lulzbot-taz-workhorse-se-0-5-mm", lib.models[i].id);
    try testing.expect(lib.findMachine("", "No Such Printer 9000") == null);
}
