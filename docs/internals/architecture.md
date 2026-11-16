# Architecture

Read [How a slicer works](how-slicing-works.md) first. It explains the stages. This document explains how the code is organized.

## Modules

```
src/
  root.zig       The public Zig API. It exports the modules and the main types.
  main.zig       The command line tool.
  c_api.zig      The C API and the wasm exports.

  Stages, in pipeline order:
  mesh.zig       Mesh, Builder (vertex weld), STL load and write, test shapes.
  slicer.zig     Layer table, face index, mesh -> layer outline.
  layer.zig      Layer plan: walls, skin, infill, path order.
  gcode.zig      Emitter: layer plans -> G-code, statistics.
  engine.zig     Job: runs all stages with threads and batches.

  Tools that the stages use:
  geom.zig       Point, Paths (flat polygon store), area, simplify.
  clip.zig       Polygon booleans.
  offset.zig     Polygon offset.
  infill.zig     Scanline line fill.
  settings.zig   Settings, Resolved (derived values), Feature.
  parallel.zig   Parallel for loop.
  svg.zig        SVG picture of a layer plan.
```

The dependencies go one way: stages use tools, and later stages use earlier stages. No tool uses a stage, with two exceptions: `svg.zig` reads a layer plan (it is an output, like `gcode.zig`), and a test in `offset.zig` uses `slicer.zig` to make a real input.

## Data flow

```
STL bytes
  -> Mesh                     (mesh.zig)
  -> []Layer, FaceIndex       (slicer.zig)
  -> []Paths  (one outline for each layer)    pass 1, parallel
  -> LayerPlan (one batch at a time)          pass 2, parallel
  -> G-code text, Stats       (gcode.zig)     in layer order
```

## Conventions

These rules hold everywhere. Code that breaks one of them makes wrong output in a later stage, not an error.

- **Units.** 2D coordinates are `i64` micrometers (`geom.Point`). Settings are `f64` millimeters. Convert with `geom.fromMm` and `geom.toMm`. Mesh vertices are `f32` millimeters.
- **Orientation.** A closed polygon has the material on its left. Outer boundaries are counterclockwise and holes are clockwise. Each boolean and offset result follows this rule. Code that makes polygons from other sources must give them the same orientation, or pass them through `clip.unionAll` with `.non_zero`.
- **Closed polygons.** A closed polygon does not repeat its first point at the end. The edge from the last point to the first point is implicit.
- **Exact predicates.** Tests on points (left of, on, crossing) use the integer functions `geom.cross3` and `geom.dot3`, in i128. Floating point is only for constructions (a new point), and the result is rounded to the grid.

## Data types

### `geom.Paths`

A set of paths in two flat arrays: `points` (all points, one path after the other) and `ends` (the end index of each path). One set has two allocations, not one for each path. `get(i)` returns the points of path i as a slice.

Build a set with `append(gpa, points)`, or point by point with `appendPoint` and `endPath`.

### `layer.LayerPlan`

The paths of one layer, in print order. It has its own arena: `deinit` frees all of it in one step. `paths.items[i]` has the feature and the closed flag of `points.get(i)`.

### `settings.Settings` and `settings.Resolved`

`Settings` has the values that the user sets. `Resolved` comes from `Settings.resolve()`: it has the derived values (the line width when it is 0, the skin layer count from the thickness, the filament area) and the `speed` function. Code after the engine start uses `Resolved`, so that each derived value has one definition.

## Memory model

zslice uses arenas for temporary memory. An arena frees all its memory in one step, so the code needs no `free` for each temporary array.

- Each boolean and offset call makes its own arena for its intermediate data. The result goes in the allocator of the caller.
- `layer.plan` uses two arenas: one for the plan (it lives until the G-code is written), and one scratch arena for intermediate shapes (freed when `plan` returns).
- `slicer.sliceAt` uses one arena for the segments and chains of a layer.

Long-lived memory:

| Data | Lifetime | Size |
|---|---|---|
| Mesh | The whole slice | 12 bytes for each vertex, 12 bytes for each triangle |
| Face index | Pass 1 | 4 bytes for each (triangle, layer) crossing |
| Outlines | The whole slice | 16 bytes for each outline point |
| Layer plans | One batch | 16 bytes for each path point |

## Threads

`parallel.forEach(threads, n, ctx, func)` runs `func(ctx, i)` for each i on a set of threads. Each thread takes the next i from one atomic counter.

- Pass 1 writes `outlines[i]` from thread i. Each slot has one writer.
- Pass 2 writes `plans[i]`. Each slot has one writer.
- The emitter runs on the calling thread, after the batch is complete.

The work of each item depends only on its index and on data that does not change during the pass. Thus the output is the same for each thread count. A test checks this (`engine.zig`).

On wasm, `parallel.has_threads` is false and the loop runs on the calling thread.

## Error handling

- Allocation errors go up to the caller as `error.OutOfMemory`.
- Bad input (a broken STL file, bad settings) returns an error from `Mesh.fromStl` or `Settings.resolve`.
- Bad geometry is not an error. A mesh with holes or overlaps gives the best output that the code can make: open chains are closed or removed, and overlaps are joined by a union.

## The C API layer

`c_api.zig` is a thin layer:

- Each exported function checks its pointers, calls the Zig API, and changes the Zig error to a status code.
- `CSettings` has `Settings` and an arena for the string values, because `Settings.set` does not copy strings.
- `CallbackWriter` is a `std.Io.Writer` that sends its buffer to the C callback.
- The wasm build compiles the same file for `wasm32-freestanding`.
