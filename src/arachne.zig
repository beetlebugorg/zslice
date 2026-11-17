//! Arachne: walls with a variable line width.
//!
//! A classic wall is an offset of the outline with a fixed line width. A
//! part that is not a whole number of line widths thick gets gaps or
//! overlaps, and a part thinner than two lines gets no wall. Arachne
//! finds the center lines of the part, measures its thickness along them,
//! and fills each thickness with a whole number of beads of a variable
//! width.
//!
//! The files:
//!
//! - `arachne/beading.zig`: the bead count and the widths for a thickness.
//!
//! They are ports to Zig of CuraEngine (AGPL-3.0-or-later). See
//! REFERENCES.md.

pub const beading = @import("arachne/beading.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
