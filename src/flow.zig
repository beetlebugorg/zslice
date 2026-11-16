//! The shape and the volume of a bead of plastic.
//!
//! The nozzle pushes the molten plastic down on the layer below. The plastic
//! spreads to the sides until it is as thin as the layer height. The nozzle
//! makes the top flat, and the layer below makes the bottom flat. The sides
//! are free, and surface tension makes them round. So the cross section of
//! a bead is a rectangle with a half circle on each side (a "stadium"):
//!
//!       ______________
//!      (              )   height h
//!       --------------
//!      |<--- width w -->|
//!
//! area = (w - h) * h + pi * h^2 / 4
//!
//! The flow model of Slic3r and PrusaSlicer uses this shape (see
//! REFERENCES.md). A rectangle (w * h, as in CuraEngine) gives 10.8 % more
//! plastic than a bead of width w holds at h = 0.2 mm and w = 0.44 mm.
//!
//! The G-code emitter uses `beadArea` to compute how much filament to push.
//! The 3D view uses `beadWidth` to draw each bead as wide as the plastic
//! that is really deposited (with the flow ratio, and the small flow of
//! ironing).

const std = @import("std");

/// The cross-section area (mm^2) of a bead of width w and height h (mm).
/// A bead narrower than its height is a round thread of diameter w.
pub fn beadArea(w: f64, h: f64) f64 {
    if (w <= h) return std.math.pi * w * w / 4;
    return (w - h) * h + std.math.pi * h * h / 4;
}

/// The width (mm) of a bead of height h with the cross-section area `area`.
/// If there is less plastic than a round thread of diameter h, the bead is a
/// round thread, and the result is its diameter.
pub fn beadWidth(area: f64, h: f64) f64 {
    const round = std.math.pi * h * h / 4;
    if (area <= round) return 2 * @sqrt(@max(area, 0) / std.math.pi);
    return (area - round) / h + h;
}

const testing = std.testing;

test "bead area and width are inverse" {
    for ([_][2]f64{ .{ 0.44, 0.2 }, .{ 0.5, 0.3 }, .{ 0.62, 0.25 }, .{ 0.15, 0.2 } }) |c| {
        try testing.expectApproxEqAbs(c[0], beadWidth(beadArea(c[0], c[1]), c[1]), 1e-12);
    }
    // 0.44 x 0.2: the bead is 0.0794 mm^2, and the rectangle is 10.8 % more.
    const rect = 0.44 * 0.2;
    try testing.expectApproxEqAbs(@as(f64, 0.0794), beadArea(0.44, 0.2), 0.0001);
    try testing.expectApproxEqRel(@as(f64, 1.108), rect / beadArea(0.44, 0.2), 0.001);
}
