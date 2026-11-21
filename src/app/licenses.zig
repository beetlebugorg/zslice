//! The licenses of zslice and of the code in its binaries, for the
//! Licenses screen of a shell. See REFERENCES.md, "Code in the binaries".

pub const License = struct {
    name: [:0]const u8,
    license: [:0]const u8,
    text: [:0]const u8,
};

/// zslice and the components in its binaries. The texts come from LICENSE
/// and licenses/ (see build.zig). A shell adds the components that only it
/// links, for example GTK.
pub const licenses = [_]License{
    .{ .name = "zslice", .license = "AGPL-3.0-or-later", .text = @embedFile("license_zslice") },
    .{ .name = "Zig standard library", .license = "MIT", .text = @embedFile("license_zig") },
    .{ .name = "musl libc (math functions)", .license = "MIT", .text = @embedFile("license_musl") },
    .{ .name = "Go (number parsing)", .license = "BSD-3-Clause", .text = @embedFile("license_go") },
    .{ .name = "ARM optimized-routines (acos, atan)", .license = "MIT", .text = @embedFile("license_arm") },
    .{ .name = "CuraEngine (Arachne walls), Copyright (c) 2026 UltiMaker", .license = "AGPL-3.0-or-later", .text = @embedFile("license_zslice") },
    .{ .name = "boost::polygon (Voronoi diagram), Copyright Andrii Sydorchuk 2010-2012", .license = "BSL-1.0", .text = @embedFile("license_boost") },
    // The printer library (src/printers/library.txt): data from the
    // printer definitions of three slicers. Native builds embed it; the web
    // app loads it as a file.
    .{ .name = "Cura printer definitions (printer library), Copyright UltiMaker", .license = "LGPL-3.0-or-later", .text = @embedFile("license_lgpl") },
    .{ .name = "GNU General Public License 3.0 (the base of the LGPL-3.0)", .license = "GPL-3.0", .text = @embedFile("license_gpl") },
    .{ .name = "PrusaSlicer printer profiles (printer library), Copyright Prusa Research", .license = "AGPL-3.0", .text = @embedFile("license_zslice") },
    .{ .name = "OrcaSlicer printer profiles (printer library), Copyright the OrcaSlicer authors", .license = "AGPL-3.0", .text = @embedFile("license_zslice") },
    // The font of the labels (src/fonts/Inter-Bold-Latin.ttf).
    .{ .name = "Inter (the font of the labels), Copyright (c) 2016 The Inter Project Authors", .license = "OFL-1.1", .text = @embedFile("license_ofl_inter") },
};
