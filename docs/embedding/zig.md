# Zig API

## Add zslice to your project

```sh
zig fetch --save git+<zslice repo url>
```

In `build.zig`:

```zig
const zslice = b.dependency("zslice", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zslice", zslice.module("zslice"));
```

## Slice to a writer

```zig
const std = @import("std");
const zslice = @import("zslice");

pub fn sliceFile(gpa: std.mem.Allocator, stl: []const u8, out: *std.Io.Writer) !zslice.Stats {
    var mesh = try zslice.Mesh.fromStl(gpa, stl);
    defer mesh.deinit(gpa);

    var settings: zslice.Settings = .{};
    // Set fields directly...
    settings.project.wall_count = 3;
    settings.filament.nozzle_temp = 220;
    // ...or by name, for example from a config file or a UI.
    try settings.set("project.infill_pattern", "lines");

    const stats = try zslice.slice(gpa, &mesh, settings, out);
    try out.flush();
    return stats;
}
```

`zslice.slice` does not flush the writer. Flush it when the slice returns.

String settings (`machine.start_gcode`, `machine.name`, and others) are slices. `Settings.set` does not copy the value. Keep the text alive until the slice returns.

## Get the paths of one layer

Use a `Job` to get the paths of a layer without G-code, for example for a preview.

```zig
var job = try zslice.Job.init(gpa, &mesh, settings);
defer job.deinit();

std.debug.print("{d} layers\n", .{job.layerCount()});

var plan = try job.planLayer(20);
defer plan.deinit();

for (plan.paths.items, 0..) |path, i| {
    const points = plan.points.get(i); // []zslice.geom.Point, in micrometers
    // path.feature: .outer_wall, .inner_wall, .skin, .infill
    // path.closed: true for a loop. The last point then connects to the first.
    _ = points;
}
```

A `LayerPlan` has:

| Field | Meaning |
|---|---|
| `index` | The layer number, from 0. |
| `z` | The nozzle height for this layer, in mm. |
| `height` | The layer height, in mm. |
| `width` | The line width, in mm. |
| `outline` | The outline of the layer: counterclockwise outer boundaries and clockwise holes. |
| `paths`, `points` | The paths in print order. `points.get(i)` gives the points of `paths.items[i]`. |
| `point_z` | For a path that is not planar (slope smoothing): `paths.items[i].z_start` is not `Path.planar`, and `point_z.items[z_start + k]` has the nozzle z (mm) and the bead area (mm²) of point k. All other paths are at `z`. |
| `point_w` | For a path whose line width changes along it (Arachne walls, `project.wall_generator = arachne`): `paths.items[i].w_start` is not `Path.planar`, and `point_w.items[w_start + k]` has the line width (mm) of point k. A segment has the mean width of its two ends. All other paths have the width `paths.items[i].width`, or `width` if that is 0. |

Coordinates are integers in micrometers (`zslice.geom.Point`). Use `zslice.geom.toMm` to change them to millimeters.

You can also write the G-code from the same job: `try job.writeGcode(out)`. A `Job` must not move in memory after `init`.

`Job.init` does the work that needs all layers: the support areas and, with `project.infill_pattern = lightning`, the lightning branches (`job.lightning`, one `Paths` for each layer). `planLayer` then plans one layer on its own.

## Make a mesh from triangles

```zig
// 9 floats for each triangle: x, y, z of 3 vertices, in mm.
// The vertices are counterclockwise as seen from outside the part.
var mesh = try zslice.Mesh.fromTriangles(gpa, xyz);
```

Or build one triangle at a time:

```zig
var b: zslice.mesh.Builder = .init(gpa);
errdefer b.deinit();
try b.addTriangle(v0, v1, v2);
var mesh = try b.finish();
```

## Allocators

- With `engine.threads` not 1, the allocator must be thread-safe.
- Good choices: `std.heap.smp_allocator` (fast, thread-safe), or `std.testing.allocator` in tests (it finds leaks).

## The lower-level modules

The root module also exports the stages, for tools that need only a part of the pipeline:

| Module | Use |
|---|---|
| `zslice.clip` | Polygon union, intersection, difference, and xor. |
| `zslice.offset` | Polygon offset. |
| `zslice.slicer` | Cut a mesh at a height. |
| `zslice.infill` | Fill a polygon set with parallel lines. |
| `zslice.svg` | Write an SVG picture of a layer plan. |

These APIs can change more often than `slice`, `Job`, `Mesh`, and `Settings`.
