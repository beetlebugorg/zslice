//! Arachne: walls with a variable line width.
//!
//! A classic wall is an offset of the outline with a fixed line width. A
//! part that is not a whole number of line widths thick gets gaps or
//! overlaps, and a part thinner than two lines gets no wall. Arachne
//! finds the center lines of the part, measures its thickness along them,
//! and fills each thickness with a whole number of beads of a variable
//! width. Where the bead count changes, a short transition joins two beads
//! into one, or splits one into two.
//!
//! The files:
//!
//! - `arachne/beading.zig`: the bead count and the widths for a thickness.
//! - `arachne/skeletal.zig`: the center line graph and the bead lines.
//! - `arachne/extrusion.zig`: the variable-width lines, stitch, simplify.
//! - `arachne/walls.zig`: the walls of one layer outline.
//!
//! They are ports to Zig of CuraEngine (AGPL-3.0-or-later). The Voronoi
//! diagram of the outline segments (`voronoi.zig`) is a port of
//! boost::polygon. See REFERENCES.md.

pub const beading = @import("arachne/beading.zig");
pub const extrusion = @import("arachne/extrusion.zig");
pub const skeletal = @import("arachne/skeletal.zig");
pub const walls = @import("arachne/walls.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
